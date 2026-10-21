// One job: the terminal itself — raw mode, window size, and what an escape is.
//
// Every answer here comes from the kernel and is returned as it came: no
// function guesses what this phone can do. measure.rs takes these answers and
// the log writes them down.
//
// No unwrap on any path: a terminal that refuses is a value, not a panic.

use libc::{c_int, termios, winsize};

/// make_raw puts one terminal into raw mode: no line discipline, no echo, no
/// signal keys. It answers what the kernel said, so a refusal is recorded.
pub fn make_raw(fd: c_int) -> Result<(), String> {
    let mut settings = termios_here(fd)?;
    unsafe {
        libc::cfmakeraw(&mut settings);
    }
    set_termios(fd, &settings)
}

/// is_raw answers whether the terminal at fd is in raw mode now, by reading
/// the settings back instead of trusting the call that set them.
pub fn is_raw(fd: c_int) -> bool {
    match termios_here(fd) {
        Ok(settings) => {
            let flags = settings.c_lflag;
            (flags & (libc::ICANON | libc::ECHO)) == 0
        }
        Err(_) => false,
    }
}

/// window_size answers the terminal's columns and rows as the kernel holds
/// them, and None when the kernel will not say.
pub fn window_size(fd: c_int) -> Option<(u16, u16)> {
    let mut size = winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let answer = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) };
    if answer == 0 {
        Some((size.ws_col, size.ws_row))
    } else {
        None
    }
}

/// set_window_size tells the terminal how big the client wants it, and answers
/// what the kernel said. The size is the only setting the holder passes on.
pub fn set_window_size(fd: c_int, cols: u16, rows: u16) -> Result<(), String> {
    let size = winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let answer = unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &size) };
    if answer == 0 {
        Ok(())
    } else {
        Err(format!("the terminal refused a size of {}x{}", cols, rows))
    }
}

/// save_termios reads the settings of the terminal at fd, so a screen that
/// changed them can put them back when it ends.
pub fn save_termios(fd: c_int) -> Result<termios, String> {
    termios_here(fd)
}

/// restore_termios writes settings back to the terminal at fd, and names the
/// syscall that refused when it does.
pub fn restore_termios(fd: c_int, settings: &termios) -> Result<(), String> {
    set_termios(fd, settings)
}

/// escape_len answers how many bytes one escape sequence at `at` holds, and 0
/// when no sequence starts there: CSI runs to its final byte, OSC to BEL or
/// ST, and any other ESC form is two bytes.
pub fn escape_len(bytes: &[u8], at: usize) -> usize {
    let first = match bytes.get(at) {
        Some(byte) => *byte,
        None => return 0,
    };
    if first != 0x1b {
        return 0;
    }
    let second = match bytes.get(at + 1) {
        Some(byte) => *byte,
        None => return 1,
    };
    match second {
        b'[' => {
            let mut i = at + 2;
            while i < bytes.len() {
                let byte = bytes[i];
                if (0x40..=0x7e).contains(&byte) {
                    return i - at + 1;
                }
                i += 1;
            }
            bytes.len() - at
        }
        b']' => {
            let mut i = at + 2;
            while i < bytes.len() {
                if bytes[i] == 0x07 {
                    return i - at + 1;
                }
                if bytes[i] == 0x1b && bytes.get(i + 1) == Some(&b'\\') {
                    return i - at + 2;
                }
                i += 1;
            }
            bytes.len() - at
        }
        _ => 2,
    }
}

/// plain answers the same bytes with escape sequences left out, so a person
/// reading the log sees what the shell said and not what the terminal drew.
pub fn plain(bytes: &[u8]) -> String {
    let mut kept: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let span = escape_len(bytes, i);
        if span > 0 {
            i += span;
        } else {
            kept.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&kept).to_string()
}

/// termios_here reads the settings of the terminal at fd, and names the
/// syscall that refused when it does.
fn termios_here(fd: c_int) -> Result<termios, String> {
    let mut settings = std::mem::MaybeUninit::<termios>::zeroed();
    let answer = unsafe { libc::tcgetattr(fd, settings.as_mut_ptr()) };
    if answer == 0 {
        Ok(unsafe { settings.assume_init() })
    } else {
        Err(format!("tcgetattr refused on fd {}", fd))
    }
}

/// set_termios writes settings back to the terminal at fd, taking effect for
/// input that has not been read yet.
fn set_termios(fd: c_int, settings: &termios) -> Result<(), String> {
    let answer = unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, settings) };
    if answer == 0 {
        Ok(())
    } else {
        Err(format!("tcsetattr refused on fd {}", fd))
    }
}
