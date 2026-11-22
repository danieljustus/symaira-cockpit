#!/usr/bin/perl
# A fake Cockpit agent for the Swift tests: it speaks the protocol of
# docs/agent-protocol.md over stdin/stdout (JSON-RPC, one message per line) and
# answers from a fixtures file. No Rust binary, no hardware, no permission is
# involved. Perl and its core JSON::PP ship with macOS.
#
#   fake-agent.pl <scenario>
#
# Environment (set by the test):
#   FAKE_AGENT_FIXTURES  JSON file: { "<command>": <output>, ... } for calls and samples
#   FAKE_AGENT_LOG       the arguments after the scenario ({argv}), then every request, one JSON line each {method, params}
#   FAKE_AGENT_MARKER    path used by `crash_once`
#
# Scenarios: ok | version (hello refused, -32010) | refuse (stderr + exit 3) |
#   crash_once (exits 7 on `call die` the first time, serves normally after a restart) |
#   confirm_denied (every `confirm` fails: permission) |
#   confirm_mixed (every `confirm` reports three items: confirmed, skipped_changed, failed) |
#   confirm_expired (every `confirm` is refused as an expired plan, a JSON-RPC error)
#
# Behaviour beyond the protocol, for deterministic tests:
#   call __tick           every subscription gets its next event (the real agent is timed)
#   call fail.permission  fails like a command refused for a missing permission
#   fan.profile / fan.target are risky: a plan first, `confirm` applies it to fan.status
#   brightness.set / warmth.set / dim.set / awake change what the next read returns
#   profile.save / profile.delete change what `profile.list` returns (reads come from the fixtures: history, profile.list)
#   battery-limit.set / battery-limit.clear are risky plans; `confirm` answers one result per item
#   Host methods (like the real app agent): services, clipboard.list/read/copy/delete/settings/configure,
#     and the register commands clipboard.status/pause/resume/clear. The fake history is stateful and
#     seeded from the fixture `__clipboard` ({settings, items:[{id,created_at,kind,size,source,text}]});
#     `__finder_jobs` is what `services` reports for the Finder jobs ({state:"off"} when absent).
use strict; use warnings; use JSON::PP;
$| = 1;
my $scenario = shift @ARGV // 'ok';
my $json = JSON::PP->new->canonical;
if ($scenario eq 'refuse') {
    print STDERR "symcockpit: agent: the parent process is not the signed com.symaira.cockpit app\n";
    exit 3;
}
my $log;
if ($ENV{FAKE_AGENT_LOG}) { open($log, '>>', $ENV{FAKE_AGENT_LOG}) or die "log: $!"; select((select($log), $| = 1)[0]); }
# The arguments after the scenario, so a test can see how the app started the agent.
print $log $json->encode({ argv => [@ARGV] }), "\n" if $log;
my $data = {};
if ($ENV{FAKE_AGENT_FIXTURES}) {
    open(my $fh, '<', $ENV{FAKE_AGENT_FIXTURES}) or die "fixtures: $!";
    local $/; $data = $json->decode(<$fh>); close $fh;
}
my @topics = qw(metrics status brightness.get awake.status fan.status processes clipboard.status);
my %risky = ('fan.profile' => 'profile', 'fan.target' => 'target', 'battery-limit.set' => 'percent', 'battery-limit.clear' => 'none');
my @reversible = qw(brightness.set warmth.set dim.set extbright.set awake profile.load profile.save profile.delete);
my @reads = (@topics, 'ai-usage', 'history', 'profile.list');
my @host_methods = qw(services clipboard.list clipboard.read clipboard.copy clipboard.delete clipboard.settings clipboard.configure);

# The hosted clipboard history, kept in memory.
my $clip = $data->{'__clipboard'} // {};
$clip->{settings} //= { enabled => JSON::PP::false, paused => JSON::PP::false,
    excluded_apps => ['com.1password.1password'], max_items => 500, max_age_secs => 2592000, max_item_bytes => 5242880 };
$clip->{items} //= [];
sub clip_status {
    my $s = $clip->{settings};
    my $on = $s->{enabled} && !$s->{paused};
    $data->{'clipboard.status'} = { enabled => $s->{enabled}, paused => $s->{paused},
        capturing => $on ? JSON::PP::true : JSON::PP::false, items => scalar(@{ $clip->{items} }),
        excluded_apps => scalar(@{ $s->{excluded_apps} }), max_items => $s->{max_items},
        max_age_days => int($s->{max_age_secs} / 86400) };
}
clip_status();
sub clip_find { my ($cid) = @_; my ($item) = grep { $_->{id} eq ($cid // '') } @{ $clip->{items} }; return $item; }

my %subs; my $next_sub = 1; my %plans; my $next_plan = 1;

sub send_frame { print $json->encode($_[0]), "\n"; }
sub reply { send_frame({ jsonrpc => "2.0", id => $_[0], result => $_[1] }); }
sub fail  { send_frame({ jsonrpc => "2.0", id => $_[0], error => $_[1] }); }
sub event {
    my ($id) = @_;
    my $s = $subs{$id} or return;
    $s->{seq}++;
    send_frame({ jsonrpc => "2.0", method => "event", params => {
        subscription_id => $id, command => $s->{command}, seq => $s->{seq},
        monotonic_ms => 100 * $s->{seq}, result => $data->{ $s->{command} } } });
}

my $hello = {
    protocol_version => 1, server_version => "9.9.9-fake",
    capabilities => {
        methods => [qw(hello call confirm subscribe unsubscribe set_visibility ping),
                    ($ENV{FAKE_AGENT_NO_HOST} ? () : @host_methods)],
        topics => [@topics], max_subscriptions => 32, min_interval_ms => 100,
        max_interval_ms => 3600000, default_interval_visible_ms => 1000,
        default_interval_hidden_ms => 10000 },
    commands => [
        (map { { name => $_, risk => "read", input_schema => { type => "object" } } } @reads),
        (map { { name => $_, risk => "reversible", input_schema => { type => "object" } } } @reversible),
        (map { { name => $_, risk => "risky", input_schema => { type => "object",
            properties => { $risky{$_} => { type => "string" } } } } } sort keys %risky),
        { name => "fan.set", risk => "risky", input_schema => { type => "object" } } ] };

while (my $line = <STDIN>) {
    chomp $line;
    next unless length $line;
    my $req = eval { $json->decode($line) } or next;
    my ($id, $method, $p) = ($req->{id}, $req->{method}, $req->{params} // {});
    print $log $json->encode({ method => $method, params => $p }), "\n" if $log;
    if ($method eq 'hello') {
        if ($scenario eq 'version') {
            fail($id, { code => -32010, message => "protocol version 1 is not supported (this agent speaks 7)",
                        data => { supported => [7], requested => 1 } });
            next;
        }
        reply($id, $hello);
    } elsif ($method eq 'call') {
        my ($c, $args) = ($p->{command}, $p->{params} // {});
        if ($c eq 'die') {
            if ($scenario eq 'crash_once' && $ENV{FAKE_AGENT_MARKER} && !-e $ENV{FAKE_AGENT_MARKER}) {
                open(my $marker, '>', $ENV{FAKE_AGENT_MARKER}) or die "marker: $!";
                close $marker;
                exit 7;
            }
            reply($id, { status => "ok", command => $c, risk => "read", output => {} });
        } elsif ($c eq '__tick') {
            reply($id, { status => "ok", command => $c, risk => "read", output => {} });
            event($_) for sort { $a <=> $b } keys %subs;
        } elsif ($c eq 'fail.permission') {
            fail($id, { code => -32000, message => "permission error: access was not granted",
                        data => { exit_code => 3, class => "permission" } });
        } elsif (exists $risky{$c}) {
            my $plan_id = "pl_" . $next_plan++;
            $plans{$plan_id} = { command => $c, params => $args };
            reply($id, { status => "confirmation_required", command => $c, risk => "risky",
                plan => { id => $plan_id, state => "pending", expires_in_s => 300, kind => "agent_command",
                          items => [ { action => "command", target => $c, command => $c, params => $args } ] } });
        } elsif ($c eq 'brightness.set') {
            $data->{'brightness.get'}{brightness} = $args->{value};
            reply($id, { status => "ok", command => $c, risk => "reversible", output => { applied => JSON::PP::true } });
        } elsif ($c eq 'warmth.set' || $c eq 'dim.set') {
            $data->{status}{active_overrides}{ $c eq 'dim.set' ? 'dim' : 'warmth' } = $args->{value};
            reply($id, { status => "ok", command => $c, risk => "reversible", output => { applied => JSON::PP::true } });
        } elsif ($c eq 'awake') {
            $data->{'awake.status'}{active} = $args->{enabled};
            $data->{'awake.status'}{prevent_display_sleep} = $args->{prevent_display_sleep} // JSON::PP::false;
            reply($id, { status => "ok", command => $c, risk => "reversible", output => { applied => JSON::PP::true } });
        } elsif ($c eq 'profile.save' || $c eq 'profile.delete') {
            my @kept = grep { $_->{name} ne $args->{name} } @{ $data->{'profile.list'}{profiles} // [] };
            push @kept, { name => $args->{name}, brightness => $data->{'brightness.get'}{brightness}, createdAt => 785000000.5, updatedAt => 785000100 } if $c eq 'profile.save';
            $data->{'profile.list'}{profiles} = \@kept;
            reply($id, { status => "ok", command => $c, risk => "reversible", output => { applied => JSON::PP::true } });
        } elsif ($c =~ /^clipboard\.(pause|resume)$/) {
            $clip->{settings}{paused} = $1 eq 'pause' ? JSON::PP::true : JSON::PP::false;
            clip_status();
            reply($id, { status => "ok", command => $c, risk => "human_only",
                output => { paused => $clip->{settings}{paused}, enabled => $clip->{settings}{enabled} } });
        } elsif ($c eq 'clipboard.clear') {
            my $n = scalar @{ $clip->{items} };
            $clip->{items} = [];
            clip_status();
            reply($id, { status => "ok", command => $c, risk => "human_only", output => { cleared => $n } });
        } elsif (grep { $_ eq $c } @reversible) {
            reply($id, { status => "ok", command => $c, risk => "reversible", output => { applied => JSON::PP::true } });
        } elsif (exists $data->{$c}) {
            reply($id, { status => "ok", command => $c, risk => "read", output => $data->{$c} });
        } else {
            fail($id, { code => -32602, message => "unknown command $c" });
        }
    } elsif ($method eq 'confirm') {
        my $plan = delete $plans{ $p->{plan_id} // '' };
        if (!$plan) {
            fail($id, { code => -32602, message => "unknown or expired plan" });
        } elsif ($scenario eq 'confirm_expired') {
            fail($id, { code => -32000, message => "usage error: plan $p->{plan_id} expired; create a new plan",
                        data => { exit_code => 2, class => "usage" } });
        } elsif ($scenario eq 'confirm_mixed') {
            reply($id, { plan_id => $p->{plan_id}, status => "failed",
                counts => { confirmed => 1, skipped_changed => 1, failed => 1 },
                results => [
                    { index => 0, action => "command", target => "/Users/example/Library/Caches/a", outcome => "confirmed" },
                    { index => 1, action => "command", target => "/Users/example/Library/Caches/b", outcome => "skipped_changed", detail => "the item changed after planning" },
                    { index => 2, action => "command", target => "/Users/example/Library/Caches/c", outcome => "failed", detail => "permission denied" } ] });
        } elsif ($scenario eq 'confirm_denied') {
            reply($id, { plan_id => $p->{plan_id}, status => "failed",
                error => { code => -32000, message => "permission error: the fan helper is not approved",
                           data => { exit_code => 3, class => "permission" } } });
        } else {
            my ($c, $args) = ($plan->{command}, $plan->{params});
            $data->{'fan.status'}{profile} = $args->{profile} if $c eq 'fan.profile';
            $data->{'fan.status'}{cool_target_celsius} = defined $args->{target} && $args->{target} ne 'off' ? $args->{target} + 0 : undef
                if $c eq 'fan.target';
            reply($id, { plan_id => $p->{plan_id}, status => "confirmed", counts => { confirmed => 1 },
                results => [ { index => 0, action => "command", target => $c, outcome => "confirmed" } ],
                output => { applied => JSON::PP::true } });
        }
    } elsif ($method eq 'subscribe') {
        unless (grep { $_ eq ($p->{command} // '') } @topics) {
            fail($id, { code => -32602, message => "$p->{command} cannot be subscribed to" });
            next;
        }
        my $sid = $next_sub++;
        $subs{$sid} = { command => $p->{command}, seq => 0 };
        reply($id, { subscription_id => $sid, command => $p->{command}, interval_ms => $p->{interval_visible_ms} // 1000 });
        event($sid);
    } elsif ($method eq 'unsubscribe') {
        delete $subs{ $p->{subscription_id} };
        reply($id, { subscription_id => $p->{subscription_id}, active => scalar(keys %subs) });
    } elsif ($method eq 'set_visibility') {
        reply($id, { visible => $p->{visible}, active => scalar(keys %subs) });
    } elsif ($method eq 'ping') {
        reply($id, {});
    } elsif (!$ENV{FAKE_AGENT_NO_HOST} && grep { $_ eq $method } @host_methods) {
        if ($method eq 'services') {
            reply($id, { clipboard => { state => $clip->{settings}{enabled} && !$clip->{settings}{paused} ? "capturing" : "off",
                                        last_error => $clip->{last_error} },
                         finder_jobs => $data->{'__finder_jobs'} // { state => "off" } });
        } elsif ($method eq 'clipboard.settings') {
            reply($id, $clip->{settings});
        } elsif ($method eq 'clipboard.list') {
            my @items = map { { id => $_->{id}, created_at => $_->{created_at}, kind => $_->{kind}, size => $_->{size} } } @{ $clip->{items} };
            splice(@items, $p->{limit}) if defined $p->{limit} && $p->{limit} < @items;
            reply($id, { count => scalar(@items), items => \@items });
        } elsif ($method eq 'clipboard.configure') {
            my @bad = grep { !/^(enabled|paused|excluded_apps|max_items|max_age_secs|max_item_bytes)$/ } keys %$p;
            if (@bad) {
                fail($id, { code => -32000, message => "usage error: clipboard settings: unknown key '$bad[0]'",
                            data => { exit_code => 2, class => "usage" } });
            } else {
                $clip->{settings}{$_} = $p->{$_} for keys %$p;
                clip_status();
                reply($id, { %{ $clip->{settings} }, state => $clip->{settings}{enabled} && !$clip->{settings}{paused} ? "capturing" : "idle",
                             last_error => $clip->{last_error} });
            }
        } else {
            my $item = clip_find($p->{id});
            if (!$item && $method eq 'clipboard.delete') {
                reply($id, { id => $p->{id}, deleted => JSON::PP::false });
            } elsif (!$item) {
                fail($id, { code => -32000, message => "clipboard item " . ($p->{id} // '') . " is gone or can no longer be opened",
                            data => { exit_code => 1, class => "error" } });
            } elsif ($method eq 'clipboard.read') {
                reply($id, { id => $item->{id}, created_at => $item->{created_at}, kind => $item->{kind}, size => $item->{size},
                             source => $item->{source},
                             ($item->{kind} eq 'image' ? (png_base64 => $item->{png_base64}) : (text => $item->{text})) });
            } elsif ($method eq 'clipboard.copy') {
                $clip->{pasteboard} = $item->{id};
                reply($id, { id => $item->{id}, copied => JSON::PP::true });
            } else {
                $clip->{items} = [ grep { $_->{id} ne $item->{id} } @{ $clip->{items} } ];
                clip_status();
                reply($id, { id => $item->{id}, deleted => JSON::PP::true });
            }
        }
    } else {
        fail($id, { code => -32601, message => "Method not found: $method" });
    }
}
exit 0;
