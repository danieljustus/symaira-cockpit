//! SIGTERM and SIGINT as a readable pipe, so a blocked event loop can wake up
//! for them without polling (the self-pipe trick). The handler only calls
//! `write`, which is async-signal-safe.

use std::fs::File;
use std::io;
use std::os::fd::FromRawFd;
use std::sync::atomic::{AtomicI32, Ordering};

static WRITE_FD: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(_signal: libc::c_int) {
    let fd = WRITE_FD.load(Ordering::Relaxed);
    if fd >= 0 {
        let byte = 1u8;
        // SAFETY: `fd` is the open, non-blocking write end made by
        // `terminate_pipe`; a full pipe (EAGAIN) already holds a wake-up.
        unsafe { libc::write(fd, (&raw const byte).cast(), 1) };
    }
}

fn cloexec(fd: libc::c_int) -> io::Result<()> {
    // SAFETY: plain fcntl calls on a descriptor this function owns.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Installs handlers for SIGTERM and SIGINT and returns the read end of a pipe
/// that receives one byte per signal. Callable once per process.
pub fn terminate_pipe() -> io::Result<File> {
    if WRITE_FD.load(Ordering::SeqCst) >= 0 {
        return Err(io::Error::other("terminate_pipe was already installed"));
    }
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: `fds` has room for the two descriptors pipe(2) returns.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } == -1 {
        return Err(io::Error::last_os_error());
    }
    let [read, write] = fds;
    cloexec(read)?;
    cloexec(write)?;
    // SAFETY: `write` is a descriptor this function owns.
    if unsafe { libc::fcntl(write, libc::F_SETFL, libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }
    WRITE_FD.store(write, Ordering::SeqCst);
    for signal in [libc::SIGTERM, libc::SIGINT] {
        // SAFETY: `on_signal` is async-signal-safe and lives for the process.
        let previous =
            unsafe { libc::signal(signal, on_signal as *const () as libc::sighandler_t) };
        if previous == libc::SIG_ERR {
            return Err(io::Error::last_os_error());
        }
    }
    // SAFETY: `read` is an open descriptor nothing else owns.
    Ok(unsafe { File::from_raw_fd(read) })
}

#[cfg(test)]
mod tests {
    use std::io::Read;

    use super::*;

    #[test]
    fn a_signal_becomes_a_byte_and_a_second_install_is_refused() {
        let mut pipe = terminate_pipe().unwrap();
        assert!(terminate_pipe().is_err());
        // SAFETY: raising a signal whose handler was just installed.
        assert_eq!(unsafe { libc::raise(libc::SIGTERM) }, 0);
        let mut byte = [0u8; 1];
        pipe.read_exact(&mut byte).unwrap();
        assert_eq!(byte, [1]);
    }
}
