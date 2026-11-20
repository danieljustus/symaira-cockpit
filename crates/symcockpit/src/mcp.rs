//! Native MCP server for `symcockpit serve`: newline-delimited JSON-RPC 2.0
//! on stdio, protocol `2025-06-18`. Stdout carries protocol frames only
//! (AGENTS.md: zero stdout pollution); nothing here prints anywhere else.
//!
//! The wire behaviour reproduces Swift's `SymairaMCP` + `TuneMCPServer` as
//! observed on the v0.12 binary (initialize, ping, error codes and messages,
//! tool results as one JSON text block with `isError: false`, handler errors
//! as `-32603`). CoreKit's `symaira-core-mcp` was evaluated and not used: it
//! speaks protocol `2024-11-05` with `Content-Length` framing, reports tool
//! failures as `isError: true` results instead of `-32603`, and pulls in
//! schemars; matching v0.12 would need more code than the ~250 lines here.
//!
//! Read tools call the native handlers; tools without one, and every write
//! tool, run the Swift core as a subprocess (see `legacy`).

use std::io::{self, BufRead, Write};

use serde_json::{Map, Value, json};
use symcockpit_contract::{CommandSpec, Error, Risk, commands};

use crate::app::{
    App, Context, DEFAULT_PROCESS_LIMIT, Output, Params, ProcessSort, ProcessesParams, Request,
};
use crate::{VERSION, json as swift_json, legacy};

pub const PROTOCOL_VERSION: &str = "2025-06-18";
/// The single-line limit of `MCPStdioTransport`; a longer line ends the session.
const MAX_LINE: usize = 50 * 1024 * 1024;

/// Tool names and descriptions in the order v0.12 lists them
/// (`TuneToolRegistry.defaultTools`, then `WriteCommand.all`). Schemas and
/// risk classes come from the contract register.
const TOOLS: [(&str, &str); 26] = [
    (
        "get_capabilities",
        "Report tool version, host info, and which tuning capabilities are available.",
    ),
    (
        "get_sensors",
        "Read thermal pressure and (when available) temperatures and fan RPM.",
    ),
    (
        "get_battery",
        "Read battery health: charge %, cycle count, capacity, condition — plus Apple's own Maximum Capacity/Condition when available.",
    ),
    (
        "list_displays",
        "List displays with EDR headroom (extended-brightness capability).",
    ),
    (
        "get_system_metrics",
        "Read system metrics: CPU utilization, memory pressure, boot disk usage, mounted storage volumes (names, paths, capacity), network throughput, and GPU device utilization percent (gpu.utilization_percent, when the IORegistry publishes it), and power. The power block separates two quantities: system_watts is the total power the whole Mac consumes (SMC PSTR, else the battery's SystemLoad; also valid on battery), while volts/amps/watts (adapter_watts) are adapter DC-in input only and read ~0 on battery. Fields the Mac does not expose are absent.",
    ),
    (
        "get_top_processes",
        "List the processes currently using the most CPU, memory or GPU — the answer to \"what is making this Mac hot/slow?\". CPU is a rate measured between two samples taken about a second apart. Processes owned by another user (root) are counted in unreadable_process_count but cannot be inspected without elevation.",
    ),
    (
        "get_ai_usage",
        "Read AI subscription/token usage per provider (OpenRouter, …). Read-only; never returns credential material. Unconfigured providers report as not set up. This tool takes no arguments and always queries every catalog provider through symbrain (credential/local-auth discovery included), regardless of which providers are enabled in the Cockpit app. To limit discovery to one provider, use the CLI: `symcockpit ai-usage <provider>`.",
    ),
    (
        "keep_awake",
        "Start or stop a keep-awake session. Prevents idle/system sleep and optionally display sleep. Runs indefinitely without duration_seconds. Returns full session state.",
    ),
    (
        "keep_awake_status",
        "Return the current keep-awake session state (active, type, remaining time, reason).",
    ),
    (
        "get_brightness",
        "Read the built-in display brightness (0.0–1.0).",
    ),
    ("save_profile", "Save current settings as a named profile."),
    ("load_profile", "Apply a saved profile by name."),
    ("list_profiles", "List all saved profiles."),
    ("delete_profile", "Delete a saved profile by name."),
    (
        "get_status",
        "Get the consolidated health status snapshot of the system, including score, recommendations, overrides, and raw reports.",
    ),
    ("get_history", "Retrieve the write operations history log."),
    (
        "set_brightness",
        "Set built-in display brightness (0.0–1.0).",
    ),
    (
        "set_extended_brightness",
        "Set extended/EDR brightness multiplier (1.0–1.6) via on-screen EDR layer.",
    ),
    (
        "set_dim",
        "Set software dim overlay (0.15=max dim, 1.0=no dim).",
    ),
    ("reset_dim", "Remove all dim overlays."),
    (
        "set_warmth",
        "Set color temperature warmth (0.0=neutral, 1.0=max warm). Uses gamma LUT.",
    ),
    (
        "reset_warmth",
        "Reset color temperature warmth to neutral (identity gamma).",
    ),
    ("restore", "Restore all overrides to system defaults."),
    (
        "set_fan",
        "Set fan speed as a fraction 0.0–1.0. Requires root/SMC write access.",
    ),
    (
        "set_charge_limit",
        "Hold battery charge at a target percent (50–100). Requires root/SMC write access.",
    ),
    (
        "clear_charge_limit",
        "Clear battery charge limit and re-enable charging. Requires root/SMC write access.",
    ),
];

pub struct Tool {
    pub name: &'static str,
    pub description: &'static str,
    pub spec: &'static CommandSpec,
}

/// The tools a client sees. Read-only mode (`mcp.mode`, `SYMTUNE_MCP_MODE`)
/// keeps exactly the `Read` tools; a hidden tool is as unknown as a typo.
pub fn tools(read_only: bool) -> Vec<Tool> {
    TOOLS
        .iter()
        .filter_map(|(name, description)| {
            let spec = commands().iter().find(|c| c.mcp_name == Some(*name))?;
            Some(Tool {
                name,
                description,
                spec,
            })
        })
        .filter(|t| !read_only || t.spec.risk == Risk::Read)
        .collect()
}

pub fn tools_list(tools: &[Tool]) -> Value {
    json!({"tools": tools.iter().map(|t| json!({
        "name": t.name,
        "description": t.description,
        "inputSchema": t.spec.input_schema,
    })).collect::<Vec<_>>()})
}

fn ok(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn fail(id: &Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

const PARSE_ERROR: i64 = -32700;
const INVALID_REQUEST: i64 = -32600;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;
const INTERNAL_ERROR: i64 = -32603;

struct Req {
    jsonrpc: Option<String>,
    id: Option<Value>,
    method: String,
    params: Option<Value>,
}

/// `MCPJSONRPCRequest` decoding: any other shape is an Invalid Request.
fn decode_request(value: &Value) -> Option<Req> {
    let o = value.as_object()?;
    let jsonrpc = match o.get("jsonrpc") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(_) => return None,
    };
    let id = match o.get("id") {
        None => None,
        Some(v @ (Value::Null | Value::String(_))) => Some(v.clone()),
        Some(Value::Number(n)) if n.is_i64() => Some(Value::Number(n.clone())),
        Some(_) => return None,
    };
    Some(Req {
        jsonrpc,
        id,
        method: o.get("method")?.as_str()?.to_owned(),
        params: o.get("params").filter(|p| !p.is_null()).cloned(),
    })
}

const NOT_AN_OBJECT: &str = "Invalid params: Type mismatch: expected Dictionary<String, Any>";

/// Missing or null `params` decode as an empty object.
fn params_object(params: Option<&Value>) -> Result<Map<String, Value>, &'static str> {
    match params {
        None => Ok(Map::new()),
        Some(Value::Object(o)) => Ok(o.clone()),
        Some(_) => Err(NOT_AN_OBJECT),
    }
}

pub struct Server<'a> {
    app: &'a App,
    ctx: &'a Context<'a>,
    tools: Vec<Tool>,
}

impl<'a> Server<'a> {
    pub fn new(app: &'a App, ctx: &'a Context<'a>) -> Self {
        Self {
            app,
            ctx,
            tools: tools(ctx.config.is_mcp_read_only()),
        }
    }

    /// The response to one line, `None` for notifications.
    pub fn handle_line(&self, line: &str) -> Option<Value> {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return Some(fail(&Value::Null, PARSE_ERROR, "Parse error"));
        };
        let Some(req) = decode_request(&value) else {
            return Some(fail(&Value::Null, INVALID_REQUEST, "Invalid Request"));
        };
        if let Some(version) = &req.jsonrpc
            && version != "2.0"
        {
            let id = req.id.clone().unwrap_or(Value::Null);
            return Some(fail(
                &id,
                INVALID_REQUEST,
                "Invalid Request: jsonrpc must be \"2.0\"",
            ));
        }
        // No id (or a null id) is a notification: handled, never answered.
        let response_id = req.id.clone().filter(|id| !id.is_null());
        let outcome = match req.method.as_str() {
            "ping" => Ok(json!({})),
            "initialize" => self.initialize(req.params.as_ref()),
            "tools/list" => Ok(tools_list(&self.tools)),
            "tools/call" => self.call(req.params.as_ref()),
            other => Err((METHOD_NOT_FOUND, format!("Method not found: {other}"))),
        };
        let id = response_id?;
        Some(match outcome {
            Ok(result) => ok(&id, result),
            Err((code, message)) => fail(&id, code, &message),
        })
    }

    fn initialize(&self, params: Option<&Value>) -> Result<Value, (i64, String)> {
        let object = params_object(params).map_err(|m| (INVALID_PARAMS, m.to_owned()))?;
        if object
            .get("protocolVersion")
            .is_some_and(|v| !v.is_null() && !v.is_string())
        {
            return Err((
                INVALID_PARAMS,
                "Invalid params: Type mismatch: expected String".into(),
            ));
        }
        Ok(json!({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": false}},
            // v0.12 reported 0.10.0 here (the embedded Tune component version);
            // the release version is the honest answer.
            "serverInfo": {"name": "symcockpit", "version": VERSION},
        }))
    }

    fn call(&self, params: Option<&Value>) -> Result<Value, (i64, String)> {
        let object = params_object(params).map_err(|m| (INVALID_PARAMS, m.to_owned()))?;
        let name = match object.get("name") {
            None => return Err((INVALID_PARAMS, "Invalid params: Missing key: name".into())),
            Some(Value::Null) => {
                return Err((
                    INVALID_PARAMS,
                    "Invalid params: Value not found: String".into(),
                ));
            }
            Some(Value::String(name)) => name.clone(),
            Some(_) => {
                return Err((
                    INVALID_PARAMS,
                    "Invalid params: Type mismatch: expected String".into(),
                ));
            }
        };
        let arguments = params_object(object.get("arguments").filter(|a| !a.is_null()))
            .map_err(|m| (INVALID_PARAMS, m.to_owned()))?;
        let tool = self
            .tools
            .iter()
            .find(|t| t.name == name)
            .ok_or_else(|| (INTERNAL_ERROR, format!("Unknown tool '{name}'.")))?;
        let text = self
            .run_tool(tool, &arguments)
            .map_err(|e| (INTERNAL_ERROR, e.to_string()))?;
        Ok(json!({"content": [{"type": "text", "text": text}], "isError": false}))
    }

    fn run_tool(&self, tool: &Tool, arguments: &Map<String, Value>) -> Result<String, Error> {
        let value = if tool.spec.risk == Risk::Read {
            self.read_tool(tool, arguments)?
        } else {
            self.write_tool(tool, arguments)?
        };
        Ok(swift_json::compact(&value))
    }

    fn read_tool(&self, tool: &Tool, arguments: &Map<String, Value>) -> Result<Value, Error> {
        let params = match tool.spec.name {
            "processes" => {
                let sort = match arguments.get("sort_by").and_then(Value::as_str) {
                    None => ProcessSort::Cpu,
                    Some(text) => ProcessSort::parse(text).ok_or_else(|| {
                        Error::Usage("sort_by must be 'cpu', 'memory' or 'gpu'.".into())
                    })?,
                };
                Params::Processes(ProcessesParams {
                    sort,
                    limit: int_argument(arguments, "limit").unwrap_or(DEFAULT_PROCESS_LIMIT),
                    interval: 1.0,
                })
            }
            "history" => Params::History {
                limit: int_argument(arguments, "limit").unwrap_or(100),
            },
            "ai-usage" => Params::AiUsage { provider: None },
            _ => Params::None,
        };
        let request = Request {
            command: tool.spec.name,
            json: true,
            params,
        };
        match crate::native::run_read(self.app, self.ctx, &request)? {
            Some(Output::Json(value)) => Ok(value),
            Some(Output::Text { .. }) => Err(Error::Failed(format!(
                "{}: handler returned text for a JSON request",
                tool.name
            ))),
            None => self.through_legacy(&legacy_read_args(&request)?),
        }
    }

    fn write_tool(&self, tool: &Tool, arguments: &Map<String, Value>) -> Result<Value, Error> {
        self.through_legacy(&write_args(tool, arguments)?)
    }

    /// Runs the Swift CLI and parses its JSON stdout. A failure's message is
    /// the `symcockpit: <message>` line the CLI printed, which is the same text
    /// the Swift MCP server puts into its error response.
    fn through_legacy(&self, args: &[String]) -> Result<Value, Error> {
        let Some(binary) = &self.app.legacy else {
            return Err(Error::Unsupported(format!(
                "the Swift core was not found; set {} or install symcockpit-legacy next to symcockpit",
                legacy::LEGACY_ENV
            )));
        };
        let mut args = args.to_vec();
        if let Some(dir) = self.ctx.data_dir_override {
            args.extend(["--data-dir".into(), dir.to_string_lossy().into_owned()]);
        }
        let captured = legacy::capture(binary, &args)?;
        if captured.code != 0 {
            return Err(Error::Failed(legacy::failure_message(&captured)));
        }
        serde_json::from_slice(&captured.stdout).map_err(|_| {
            Error::Failed(format!(
                "symcockpit {} printed no JSON",
                args.first().map_or("", String::as_str)
            ))
        })
    }
}

/// `MCPJSONValue.intValue`: an integral number within ±2^53.
fn int_argument(arguments: &Map<String, Value>, key: &str) -> Option<i64> {
    let n = arguments.get(key)?.as_f64()?;
    (n.fract() == 0.0 && n.abs() <= 9_007_199_254_740_992.0).then_some(n as i64)
}

/// CLI arguments of a read tool without a native handler.
fn legacy_read_args(request: &Request) -> Result<Vec<String>, Error> {
    let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    Ok(match (request.command, &request.params) {
        ("doctor" | "sensors" | "battery" | "displays" | "metrics", _) => words(&[request.command]),
        ("awake.status", _) => words(&["awake", "status"]),
        ("brightness.get", _) => words(&["brightness", "get"]),
        ("status", _) => words(&["status", "--json"]),
        ("processes", Params::Processes(p)) => {
            vec![
                "processes".into(),
                "--json".into(),
                "--sort".into(),
                p.sort.as_str().into(),
                "--limit".into(),
                p.limit.to_string(),
            ]
        }
        (other, _) => return Err(Error::Failed(format!("{other}: no way to run this tool"))),
    })
}

/// `requireDouble`: a number, or a string that parses as one.
fn require_double(arguments: &Map<String, Value>, name: &str) -> Result<f64, Error> {
    let number = match arguments.get(name) {
        Some(Value::Number(n)) => n.as_f64(),
        Some(Value::String(s)) => s.parse::<f64>().ok(),
        _ => None,
    };
    match number {
        Some(n) if n.is_finite() => Ok(n),
        Some(_) => Err(Error::Usage("Value must be finite.".into())),
        None => Err(Error::Usage(format!(
            "Missing required numeric argument '{name}'."
        ))),
    }
}

/// `requireInt`: an integral number, or a string that parses as an integer.
fn require_int(arguments: &Map<String, Value>, name: &str) -> Result<i64, Error> {
    int_argument(arguments, name)
        .or_else(|| arguments.get(name)?.as_str()?.parse().ok())
        .ok_or_else(|| Error::Usage(format!("Missing required integer argument '{name}'.")))
}

/// The CLI line equivalent to a write tool (`WriteCommand.cliPrefix` plus the
/// value), after the same argument validation the Swift tool performs.
fn write_args(tool: &Tool, arguments: &Map<String, Value>) -> Result<Vec<String>, Error> {
    let spec = tool.spec;
    match spec.name {
        // keep_awake holds its assertion inside the server process in v0.12;
        // a CLI subprocess cannot, so starting a session is not available yet.
        "awake" => {
            if !arguments
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                return Ok(vec!["awake".into(), "off".into()]);
            }
            validate_duration(arguments.get("duration_seconds"))?;
            Err(Error::Unsupported("keep_awake sessions need the long-lived Swift server; use `symcockpit awake` in a terminal for now".into()))
        }
        "profile.save" | "profile.load" | "profile.delete" => {
            let name = arguments
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| Error::Usage(format!("{} requires a name.", tool.name)))?;
            let mut args: Vec<String> = spec.cli_path.split(' ').map(str::to_owned).collect();
            args.push(name.to_owned());
            Ok(args)
        }
        _ => {
            let mut args: Vec<String> = spec.cli_path.split(' ').map(str::to_owned).collect();
            if let Some((argument, schema)) = spec.input_schema["properties"]
                .as_object()
                .and_then(|p| p.iter().next())
            {
                args.push(if schema["type"] == "integer" {
                    require_int(arguments, argument)?.to_string()
                } else {
                    require_double(arguments, argument)?.to_string()
                });
            }
            Ok(args)
        }
    }
}

/// `KeepAwakeTool.validatedDuration`.
fn validate_duration(value: Option<&Value>) -> Result<(), Error> {
    let Some(value) = value.filter(|v| !v.is_null()) else {
        return Ok(());
    };
    let usage = |m: &str| Err(Error::Usage(m.into()));
    let Some(duration) = value.as_f64() else {
        return usage("keep_awake duration_seconds must be a number.");
    };
    if !duration.is_finite() {
        return usage("keep_awake duration_seconds must be finite.");
    }
    if duration < 0.0 {
        return usage("keep_awake duration_seconds must be non-negative.");
    }
    if duration > 86_400.0 {
        return usage("keep_awake duration_seconds must not exceed 86400 seconds (24 hours).");
    }
    Ok(())
}

enum Line {
    Text(Vec<u8>),
    TooLong,
    Eof,
}

/// One line without its newline, never buffering more than `MAX_LINE`.
fn read_line(input: &mut impl BufRead) -> io::Result<Line> {
    let mut line = Vec::new();
    loop {
        let buffer = input.fill_buf()?;
        if buffer.is_empty() {
            return Ok(if line.is_empty() {
                Line::Eof
            } else {
                Line::Text(line)
            });
        }
        let (chunk, found) = match buffer.iter().position(|b| *b == b'\n') {
            Some(i) => (i, true),
            None => (buffer.len(), false),
        };
        line.extend_from_slice(&buffer[..chunk]);
        input.consume(chunk + usize::from(found));
        if line.len() > MAX_LINE {
            return Ok(Line::TooLong);
        }
        if found {
            return Ok(Line::Text(line));
        }
    }
}

/// Serves until end of input. Responses are flushed one by one, in order.
pub fn serve(server: &Server, mut input: impl BufRead, mut output: impl Write) -> io::Result<()> {
    loop {
        let bytes = match read_line(&mut input)? {
            Line::Text(bytes) => bytes,
            Line::TooLong | Line::Eof => return Ok(()),
        };
        let text = String::from_utf8_lossy(&bytes);
        let line = text.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(response) = server.handle_line(line)
            && writeln!(output, "{response}")
                .and_then(|()| output.flush())
                .is_err()
        {
            // The client went away.
            return Ok(());
        }
    }
}
