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
#   FAKE_AGENT_LOG       every request is appended here as one JSON line {method, params}
#   FAKE_AGENT_MARKER    path used by `crash_once`
#
# Scenarios: ok | version (hello refused, -32010) | refuse (stderr + exit 3) |
#   crash_once (exits 7 on `call die` the first time, serves normally after a restart)
#
# Behaviour beyond the protocol, for deterministic tests:
#   call __tick           every subscription gets its next event (the real agent is timed)
#   call fail.permission  fails like a command refused for a missing permission
#   fan.profile / fan.target are risky: a plan first, `confirm` applies it to fan.status
#   brightness.set / warmth.set / dim.set / awake change what the next read returns
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
my $data = {};
if ($ENV{FAKE_AGENT_FIXTURES}) {
    open(my $fh, '<', $ENV{FAKE_AGENT_FIXTURES}) or die "fixtures: $!";
    local $/; $data = $json->decode(<$fh>); close $fh;
}
my @topics = qw(metrics status brightness.get awake.status fan.status processes);
my %risky = ('fan.profile' => 'profile', 'fan.target' => 'target');
my @reversible = qw(brightness.set warmth.set dim.set extbright.set awake);
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
        methods => [qw(hello call confirm subscribe unsubscribe set_visibility ping)],
        topics => [@topics], max_subscriptions => 32, min_interval_ms => 100,
        max_interval_ms => 3600000, default_interval_visible_ms => 1000,
        default_interval_hidden_ms => 10000 },
    commands => [
        (map { { name => $_, risk => "read", input_schema => { type => "object" } } } (@topics, 'ai-usage')),
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
        } elsif ($scenario eq 'confirm_denied') {
            reply($id, { plan_id => $p->{plan_id}, status => "failed",
                error => { code => -32000, message => "permission error: the fan helper is not approved",
                           data => { exit_code => 3, class => "permission" } } });
        } else {
            my ($c, $args) = ($plan->{command}, $plan->{params});
            $data->{'fan.status'}{profile} = $args->{profile} if $c eq 'fan.profile';
            $data->{'fan.status'}{cool_target_celsius} = defined $args->{target} && $args->{target} ne 'off' ? $args->{target} + 0 : undef
                if $c eq 'fan.target';
            reply($id, { plan_id => $p->{plan_id}, status => "confirmed", output => { applied => JSON::PP::true } });
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
    } else {
        fail($id, { code => -32601, message => "Method not found: $method" });
    }
}
exit 0;
