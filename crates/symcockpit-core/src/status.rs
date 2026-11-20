//! `status` / MCP `get_status`: the consolidated health snapshot
//! (`HealthScorer.swift`, `StatusReport`, `runStatus` in v0.12).
//!
//! The sensor, battery and display reports come from their own areas as JSON
//! objects; this module only scores and renders them. Required fields that are
//! missing are an error, so a wiring mistake cannot silently skew the score.

use serde_json::{Value, json};
use symcockpit_contract::Error;

pub const DEFAULT_INTERVAL: f64 = 1.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Options {
    pub watch: bool,
    pub interval: f64,
    pub json: bool,
}

/// `DurationParser.parse`: `500ms`, `2s`, `5m`, `1h` or plain seconds.
pub fn parse_duration(text: &str) -> Result<f64, Error> {
    let t = text.trim();
    if t.is_empty() {
        return Err(Error::Usage("Duration string cannot be empty".into()));
    }
    let (number, scale) = if let Some(n) = t.strip_suffix("ms") {
        (n, 0.001)
    } else if let Some(n) = t.strip_suffix('s') {
        (n, 1.0)
    } else if let Some(n) = t.strip_suffix('m') {
        (n, 60.0)
    } else if let Some(n) = t.strip_suffix('h') {
        (n, 3600.0)
    } else {
        (t, 1.0)
    };
    let value: f64 = number
        .parse()
        .map_err(|_| Error::Usage(format!("Invalid numeric value for duration: '{t}'")))?;
    // Swift divides by 1000 for `ms` rather than multiplying by 0.001.
    Ok(if scale == 0.001 {
        value / 1000.0
    } else {
        value * scale
    })
}

/// `status [--json] [--watch [--interval <duration>]]` (`StatusOptions.parseOptions`).
pub fn parse_options(args: &[String]) -> Result<Options, Error> {
    let mut o = Options {
        watch: false,
        interval: DEFAULT_INTERVAL,
        json: false,
    };
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--watch" => o.watch = true,
            "--interval" => {
                i += 1;
                let value = args
                    .get(i)
                    .ok_or_else(|| Error::Usage("status: --interval requires a value.".into()))?;
                o.interval = parse_duration(value)?;
                if !o.interval.is_finite() || o.interval <= 0.0 {
                    return Err(Error::Usage(
                        "status: --interval must be finite and positive.".into(),
                    ));
                }
            }
            "--json" => o.json = true,
            other => return Err(Error::Usage(format!("status: unknown option '{other}'"))),
        }
        i += 1;
    }
    Ok(o)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Health {
    pub score: i64,
    pub message: &'static str,
    pub recommendations: Vec<String>,
}

fn missing(what: &str) -> Error {
    Error::Failed(format!("status: report is missing '{what}'"))
}

/// `HealthScorer.calculateScore`.
pub fn health_score(
    sensors: &Value,
    battery: &Value,
    overrides: &Value,
    keep_awake: bool,
) -> Result<Health, Error> {
    let mut score: i64 = 100;
    let mut rec: Vec<String> = Vec::new();

    match sensors
        .get("thermal_pressure")
        .and_then(Value::as_str)
        .ok_or_else(|| missing("sensors.thermal_pressure"))?
    {
        "fair" => {
            score -= 10;
            rec.push("System is under fair thermal pressure. Consider cooling down.".into());
        }
        "serious" => {
            score -= 30;
            rec.push("System thermal pressure is serious. Performance may be throttled.".into());
        }
        "critical" => {
            score -= 60;
            rec.push("System thermal pressure is critical. Close heavy apps immediately.".into());
        }
        _ => {}
    }
    if !sensors
        .get("smc_supported")
        .and_then(Value::as_bool)
        .ok_or_else(|| missing("sensors.smc_supported"))?
    {
        score -= 10;
        rec.push(
            "SMC connection failed. Detailed sensor temperatures and fan RPM are unavailable."
                .into(),
        );
    }
    if battery
        .get("present")
        .and_then(Value::as_bool)
        .ok_or_else(|| missing("battery.present"))?
    {
        if let Some(health) = battery.get("health_percent").and_then(Value::as_i64)
            && health < 80
        {
            score -= (80 - health).min(30);
            rec.push(format!(
                "Battery health is degraded ({health}%). Consider servicing the battery."
            ));
        }
        if let Some(cycles) = battery.get("cycle_count").and_then(Value::as_i64)
            && cycles > 1000
        {
            score -= 10;
            rec.push(format!("Battery cycle count is high ({cycles})."));
        }
        if let Some(temp) = battery.get("temperature_celsius").and_then(Value::as_f64) {
            if temp > 45.0 {
                score -= 15;
                rec.push(format!(
                    "Battery temperature is critically hot ({temp:.1}°C). Stop heavy tasks."
                ));
            } else if temp > 35.0 {
                score -= 5;
                rec.push(format!("Battery temperature is warm ({temp:.1}°C)."));
            }
        }
    }
    if keep_awake {
        rec.push("Keep-awake assertion is active, preventing system sleep.".into());
    }
    let num = |key: &str| overrides.get(key).and_then(Value::as_f64);
    if let Some(b) = num("brightness")
        && b > 0.9
    {
        rec.push(format!(
            "Display brightness is set very high ({}%), which increases power drain.",
            (b * 100.0) as i64
        ));
    }
    if let Some(d) = num("dim")
        && d < 1.0
    {
        rec.push(format!(
            "Software dim overlay is active (dimmed to {}%).",
            (d * 100.0) as i64
        ));
    }
    if num("warmth").is_some_and(|w| w > 0.0) {
        rec.push("Warmth override (color shift) is active.".into());
    }
    if let Some(edr) = num("edr_brightness")
        && edr > 1.0
    {
        rec.push(format!(
            "Extended EDR brightness is active ({edr:.1}x), which increases thermal load."
        ));
    }

    let score = score.clamp(0, 100);
    let message = match score {
        90..=100 => "System health is optimal.",
        70..=89 => "System health is good, with minor warnings.",
        50..=69 => "System health is degraded. Action may be required.",
        _ => "System health is critical. Performance or battery may be severely impacted.",
    };
    if rec.is_empty() {
        rec.push("System is running optimally with no warnings.".into());
    }
    Ok(Health {
        score,
        message,
        recommendations: rec,
    })
}

/// The `StatusReport` object. `overrides` is `ActiveOverrides` as JSON
/// (`brightness`, `dim`, `warmth`, `edr_brightness`, `fan_fraction`,
/// `charge_limit_percent`, `charge_limit_state`; absent when not active).
pub fn status_json(
    sensors: Value,
    battery: Value,
    displays: Value,
    overrides: Value,
    keep_awake: bool,
) -> Result<Value, Error> {
    let health = health_score(&sensors, &battery, &overrides, keep_awake)?;
    Ok(json!({
        "health_score": health.score,
        "health_score_msg": health.message,
        "recommendations": health.recommendations,
        "active_overrides": overrides,
        "sensors": sensors,
        "battery": battery,
        "displays": displays,
    }))
}

/// The text form of `status` (without `--json`).
pub fn status_text(report: &Value) -> String {
    let mut out = format!(
        "symcockpit health: {} (Score: {}/100)\n\nRecommendations:\n",
        report["health_score_msg"].as_str().unwrap_or(""),
        report["health_score"].as_i64().unwrap_or(0)
    );
    for rec in report["recommendations"].as_array().into_iter().flatten() {
        out.push_str(&format!("- {}\n", rec.as_str().unwrap_or("")));
    }
    out.push_str("\nActive Overrides:\n");
    let o = &report["active_overrides"];
    let num = |key: &str| o.get(key).and_then(Value::as_f64);
    let mut any = false;
    let mut line = |text: String| {
        out.push_str(&text);
        out.push('\n');
        any = true;
    };
    if let Some(b) = num("brightness") {
        line(format!("- Brightness: {}%", (b * 100.0) as i64));
    }
    if let Some(d) = num("dim") {
        line(format!("- Software Dim: {}%", (d * 100.0) as i64));
    }
    if let Some(w) = num("warmth") {
        line(format!("- Warmth: {}%", (w * 100.0) as i64));
    }
    if let Some(e) = num("edr_brightness") {
        line(format!("- Extended EDR Brightness: {e:.1}x"));
    }
    if let Some(f) = num("fan_fraction") {
        line(format!("- Fan: {}%", (f * 100.0) as i64));
    }
    if let Some(c) = o.get("charge_limit_percent").and_then(Value::as_i64) {
        let state = o
            .get("charge_limit_state")
            .and_then(Value::as_str)
            .map_or_else(String::new, |s| format!(" ({s})"));
        line(format!("- Charge Limit: {c}%{state}"));
    }
    if !any {
        out.push_str("- None\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| (*s).to_owned()).collect()
    }

    fn sensors(pressure: &str, smc: bool) -> Value {
        json!({"thermal_pressure": pressure, "smc_supported": smc})
    }

    fn battery() -> Value {
        json!({"present": true, "health_percent": 86, "cycle_count": 171})
    }

    #[test]
    fn options_and_durations() {
        let o = parse_options(&args(&["--watch", "--interval", "500ms", "--json"])).unwrap();
        assert_eq!(
            o,
            Options {
                watch: true,
                interval: 0.5,
                json: true
            }
        );
        assert_eq!(
            parse_options(&[]).unwrap(),
            Options {
                watch: false,
                interval: 1.0,
                json: false
            }
        );
        for (bad, msg) in [
            (&["--interval"][..], "status: --interval requires a value."),
            (
                &["--interval", "0"],
                "status: --interval must be finite and positive.",
            ),
            (
                &["--interval", "-2s"],
                "status: --interval must be finite and positive.",
            ),
            (
                &["--interval", "inf"],
                "status: --interval must be finite and positive.",
            ),
            (
                &["--interval", "abc"],
                "Invalid numeric value for duration: 'abc'",
            ),
            (&["--bogus"], "status: unknown option '--bogus'"),
            (&["--help"], "status: unknown option '--help'"),
        ] {
            let e = parse_options(&args(bad)).unwrap_err();
            assert_eq!((e.to_string().as_str(), e.exit_code()), (msg, 2), "{bad:?}");
        }
        for (text, secs) in [
            ("2", 2.0),
            ("1.5s", 1.5),
            ("2m", 120.0),
            ("1h", 3600.0),
            (" 3 ", 3.0),
        ] {
            assert_eq!(parse_duration(text).unwrap(), secs, "{text}");
        }
        assert_eq!(
            parse_duration("").unwrap_err().to_string(),
            "Duration string cannot be empty"
        );
    }

    #[test]
    fn healthy_system_scores_100() {
        let h = health_score(&sensors("nominal", true), &battery(), &json!({}), false).unwrap();
        assert_eq!(
            h,
            Health {
                score: 100,
                message: "System health is optimal.",
                recommendations: vec!["System is running optimally with no warnings.".into()]
            }
        );
    }

    #[test]
    fn deductions_messages_and_bands() {
        let hot = json!({"present": true, "health_percent": 60, "cycle_count": 1200, "temperature_celsius": 46.04});
        let h = health_score(&sensors("serious", false), &hot, &json!({}), true).unwrap();
        // 100 - 30 (serious) - 10 (no SMC) - 20 (health) - 10 (cycles) - 15 (hot)
        assert_eq!(h.score, 15);
        assert_eq!(
            h.message,
            "System health is critical. Performance or battery may be severely impacted."
        );
        assert_eq!(
            h.recommendations,
            [
                "System thermal pressure is serious. Performance may be throttled.",
                "SMC connection failed. Detailed sensor temperatures and fan RPM are unavailable.",
                "Battery health is degraded (60%). Consider servicing the battery.",
                "Battery cycle count is high (1200).",
                "Battery temperature is critically hot (46.0°C). Stop heavy tasks.",
                "Keep-awake assertion is active, preventing system sleep."
            ]
        );
        // Health deficit is capped at 30; warm battery; critical pressure floors at 0.
        let weak = json!({"present": true, "health_percent": 10, "temperature_celsius": 36.0});
        assert_eq!(
            health_score(&sensors("fair", true), &weak, &json!({}), false)
                .unwrap()
                .score,
            100 - 10 - 30 - 5
        );
        assert_eq!(
            health_score(
                &sensors("critical", false),
                &json!({"present": false, "health_percent": 1}),
                &json!({}),
                false
            )
            .unwrap()
            .score,
            30
        );
        let floor = json!({"present": true, "health_percent": 0, "cycle_count": 5000, "temperature_celsius": 50});
        assert_eq!(
            health_score(&sensors("critical", false), &floor, &json!({}), false)
                .unwrap()
                .score,
            0
        );
        for (pressure, smc, band) in [
            ("nominal", true, "optimal"),
            ("serious", true, "good"),
            ("serious", false, "degraded"),
        ] {
            let m = health_score(&sensors(pressure, smc), &battery(), &json!({}), false)
                .unwrap()
                .message;
            assert!(m.contains(band), "{m}");
        }
        // Unknown thermal pressure costs nothing, like Swift's `unknown`.
        assert_eq!(
            health_score(&sensors("unknown", true), &battery(), &json!({}), false)
                .unwrap()
                .score,
            100
        );
    }

    #[test]
    fn override_recommendations_use_truncating_percentages() {
        let o = json!({"brightness": 0.95, "dim": 0.29, "warmth": 0.2, "edr_brightness": 1.44, "fan_fraction": 0.5});
        let h = health_score(&sensors("nominal", true), &battery(), &o, false).unwrap();
        assert_eq!(
            h.recommendations,
            [
                "Display brightness is set very high (95%), which increases power drain.",
                "Software dim overlay is active (dimmed to 28%).",
                "Warmth override (color shift) is active.",
                "Extended EDR brightness is active (1.4x), which increases thermal load."
            ]
        );
        assert_eq!(h.score, 100);
    }

    #[test]
    fn missing_required_fields_are_errors_not_silent_defaults() {
        for (s, b) in [
            (json!({"smc_supported": true}), battery()),
            (json!({"thermal_pressure": "nominal"}), battery()),
            (sensors("nominal", true), json!({})),
        ] {
            let e = health_score(&s, &b, &json!({}), false).unwrap_err();
            assert!(matches!(e, Error::Failed(_)), "{e}");
        }
    }

    #[test]
    fn report_embeds_the_area_reports_untouched() {
        let r = status_json(
            sensors("nominal", true),
            battery(),
            json!({"displays": []}),
            json!({"fan_fraction": 0.658}),
            false,
        )
        .unwrap();
        assert_eq!(r["health_score"], 100);
        assert_eq!(r["active_overrides"], json!({"fan_fraction": 0.658}));
        assert_eq!(r["displays"], json!({"displays": []}));
        assert_eq!(r["sensors"]["thermal_pressure"], "nominal");
    }

    #[test]
    fn text_form_lists_overrides_or_none() {
        let none = status_json(
            sensors("nominal", true),
            battery(),
            json!({}),
            json!({}),
            false,
        )
        .unwrap();
        assert_eq!(
            status_text(&none),
            "symcockpit health: System health is optimal. (Score: 100/100)\n\nRecommendations:\n- System is running optimally with no warnings.\n\nActive Overrides:\n- None\n"
        );
        let o = json!({"brightness": 0.5, "dim": 0.5, "warmth": 0.25, "edr_brightness": 1.25, "fan_fraction": 0.658, "charge_limit_percent": 80, "charge_limit_state": "lapsed"});
        let all = status_json(sensors("nominal", true), battery(), json!({}), o, false).unwrap();
        let text = status_text(&all);
        assert!(text.ends_with("Active Overrides:\n- Brightness: 50%\n- Software Dim: 50%\n- Warmth: 25%\n- Extended EDR Brightness: 1.2x\n- Fan: 65%\n- Charge Limit: 80% (lapsed)\n"), "{text}");
    }
}
