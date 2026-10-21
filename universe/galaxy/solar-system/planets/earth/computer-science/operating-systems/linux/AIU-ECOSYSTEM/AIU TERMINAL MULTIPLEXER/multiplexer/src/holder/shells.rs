// One job: the shells of one session — started on a terminal, tracked, and
// kept alive whatever the clients do.
//
// The shell belongs to the session, not to a client: a client that goes away
// changes nothing here (rule 01). Everything that touches a terminal goes
// through the tty facade, so there is one way to open a pty.

use crate::facade;
use crate::measure;

/// Shell is one program running on a terminal of this session.
pub struct Shell {
    pub pid: libc::pid_t,
    pub master: libc::c_int,
    pub program: String,
    pub measured: measure::Measured,
}

impl Shell {
    /// start opens a terminal and runs one program on it, sized as asked.
    pub fn start(program: &str, args: &[String], cols: u16, rows: u16) -> Result<Shell, String> {
        let pty = facade::open_shell(program, args, cols, rows)?;
        Ok(Shell {
            pid: pty.pid,
            master: pty.master,
            program: program.to_string(),
            measured: pty.measured,
        })
    }

    /// alive_now asks the kernel whether the shell is still there, and answers
    /// the fact as it is: a shell that ended is not a shell that is quiet.
    pub fn alive_now(&self) -> bool {
        unsafe { libc::kill(self.pid, 0) == 0 }
    }

    /// send puts bytes into the shell's terminal and answers when they are
    /// all in.
    pub fn send(&self, bytes: &[u8]) -> Result<(), String> {
        facade::write_bytes(self.master, bytes)
    }

    /// read waits for the shell to have bytes and answers how many came; 0
    /// means the shell is gone.
    pub fn read(&self, buffer: &mut [u8]) -> Result<usize, String> {
        facade::read_bytes(self.master, buffer)
    }

    /// wait blocks until the shell ends — an event, never a poll — and answers
    /// the way a person would read it.
    pub fn wait(&self) -> String {
        facade::wait_exit(self.pid)
    }
}
