fn main() -> std::process::ExitCode {
    symcockpit::run(std::env::args_os().skip(1).collect()).into()
}
