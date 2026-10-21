// One job: the screen — the panes drawn on one terminal, the mode line, the
// tab bar, the keymap explorer, and the redraw when something arrives.
//
// The screen holds nothing: the panes, their shells and their output belong
// to the holder. What lives here is what the owner sees and what the owner
// presses.
//
// The keys are read through the keymap (=keymap.rs=): the same table says
// what the keys do and what the explorer shows, so the two cannot drift
// apart. The modes are Visual (the multiplexer's own keys), Insert (the
// pane's own keys), Command (the command line) and Explorer (the keymap
// explorer).

use serde_json::{json, Value};
use std::io::Write;

use super::keymap::{bindings, Command, Context, Keymap, Mode, Resolution, State};
use super::tty;
use super::wire;

/// ESCAPE leaves Insert, and cancels a sequence or the explorer.
const ESCAPE: u8 = 0x1b;
/// ENTER ends a command line.
const ENTER: u8 = 0x0d;
/// BACKSPACE takes the last character off the command line.
const BACKSPACE: u8 = 0x7f;
/// KEPT is how many lines of a pane's output the screen remembers.
const KEPT: usize = 400;

/// Action is what the client does with the holder after a key.
pub enum Action {
    Nothing,
    /// Send puts the bytes into the focused pane's own program.
    Send(Vec<u8>),
    /// Request asks the holder to do one thing.
    Request(Value),
    /// Quit leaves the multiplexer; the session goes on.
    Quit,
}

/// PaneView is one pane as the screen sees it: its name, its tab, how much
/// of the layout it wants, and what its program said.
pub struct PaneView {
    pub name: String,
    pub tab: String,
    pub weight: u16,
    pub lines: Vec<String>,
}

/// Rect is one pane's place on the terminal: where it starts and how big it
/// is. The rows and the columns are 1-based, the way the terminal counts.
struct Rect {
    top: u16,
    left: u16,
    rows: u16,
    cols: u16,
}

/// Panel is the box that lies over the panes: the keymap explorer, the
/// records, or the sessions.
struct Panel {
    title: String,
    lines: Vec<String>,
}

/// Screen is what the owner sees: the tabs, the panes of the current tab, the
/// focus, the mode, the command line, and the size of the window.
pub struct Screen {
    pub direction: String,
    pub tabs: Vec<String>,
    pub tab: usize,
    pub panes: Vec<PaneView>,
    pub focused: usize,
    pub mode: Mode,
    pub command: String,
    pub cols: u16,
    pub rows: u16,
    pub agent_program: String,
    pub editor_program: String,
    pub message: String,
    pub events: Vec<String>,
    keymap: Keymap,
    panel: Option<Panel>,
}

impl Screen {
    /// empty is a screen with nothing on it yet: the holder's state fills it
    /// in as soon as the state arrives.
    pub fn empty(agent_program: String, editor_program: String) -> Screen {
        Screen {
            direction: "row".to_string(),
            tabs: Vec::new(),
            tab: 0,
            panes: Vec::new(),
            focused: 0,
            mode: Mode::Visual,
            command: String::new(),
            cols: 0,
            rows: 0,
            agent_program,
            editor_program,
            message: String::new(),
            events: Vec::new(),
            keymap: Keymap::empty(),
            panel: None,
        }
    }

    /// state answers what the multiplexer holds right now, so a binding can
    /// say whether it can run.
    pub fn state(&self) -> State {
        State {
            tabs: self.tabs.len(),
            panes: self.panes.len(),
        }
    }

    /// take_state reads the holder's state record into the screen: the
    /// direction, the tabs, and the panes with their names and their weights.
    /// The pane's own text is kept: the state does not carry it.
    pub fn take_state(&mut self, record: &Value) {
        let outputs = match record.get("outputs") {
            Some(found) => found,
            None => return,
        };
        if outputs.get("session").is_none() || outputs.get("panes").is_none() {
            return;
        }
        if let Some(direction) = outputs.get("direction").and_then(|value| value.as_str()) {
            self.direction = direction.to_string();
        }
        let mut tabs: Vec<String> = Vec::new();
        if let Some(list) = outputs.get("tabs").and_then(|value| value.as_array()) {
            for tab in list {
                if let Some(name) = tab.as_str() {
                    tabs.push(name.to_string());
                }
            }
        }
        if !tabs.is_empty() {
            self.tabs = tabs;
        }
        let mut panes: Vec<PaneView> = Vec::new();
        if let Some(list) = outputs.get("panes").and_then(|value| value.as_array()) {
            for pane in list {
                let name = pane
                    .get("name")
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();
                let tab = pane
                    .get("tab")
                    .and_then(|value| value.as_str())
                    .unwrap_or("main")
                    .to_string();
                let weight = pane
                    .get("weight")
                    .and_then(|value| value.as_u64())
                    .unwrap_or(1) as u16;
                let lines = self
                    .panes
                    .iter()
                    .find(|held| held.name == name)
                    .map(|held| held.lines.clone())
                    .unwrap_or_default();
                panes.push(PaneView {
                    name,
                    tab,
                    weight,
                    lines,
                });
            }
        }
        if self.focused >= panes.len() {
            self.focused = 0;
        }
        self.panes = panes;
    }

    /// push_text puts what a pane's program said into that pane's memory.
    pub fn push_text(&mut self, pane: &str, text: &str) {
        if let Some(held) = self.panes.iter_mut().find(|held| held.name == pane) {
            for line in text.lines() {
                held.lines.push(line.to_string());
            }
            if held.lines.len() > KEPT {
                let extra = held.lines.len() - KEPT;
                held.lines.drain(0..extra);
            }
        }
    }

    /// tab_panes answers the panes of the tab the owner stands in.
    fn tab_panes(&self) -> Vec<usize> {
        if self.tabs.is_empty() {
            return (0..self.panes.len()).collect();
        }
        let tab = self.tabs.get(self.tab).cloned().unwrap_or_default();
        let members: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter(|(_, pane)| pane.tab == tab)
            .map(|(at, _)| at)
            .collect();
        if members.is_empty() {
            (0..self.panes.len()).collect()
        } else {
            members
        }
    }

    /// focused_pane answers the name of the pane that has the focus.
    fn focused_pane(&self) -> String {
        self.panes
            .get(self.focused)
            .map(|pane| pane.name.clone())
            .unwrap_or_default()
    }

    /// focused_tab answers the name of the tab the owner stands in.
    fn focused_tab(&self) -> String {
        self.tabs
            .get(self.tab)
            .cloned()
            .unwrap_or_else(|| "main".to_string())
    }

    /// rects answers where each pane of the current tab sits on the terminal.
    fn rects(&self, cols: u16, rows: u16) -> Vec<Rect> {
        let members = self.tab_panes();
        let total: u32 = members
            .iter()
            .map(|at| self.panes[*at].weight.max(1) as u32)
            .sum();
        let total = total.max(1);
        let mut rects: Vec<Rect> = Vec::new();
        if self.direction == "column" {
            let mut top: u16 = 1;
            let mut used: u32 = 0;
            for (at, index) in members.iter().enumerate() {
                let weight = self.panes[*index].weight.max(1) as u32;
                let height = if at + 1 == members.len() {
                    (rows as u32).saturating_sub(used)
                } else {
                    (rows as u32 * weight) / total
                };
                used += height;
                rects.push(Rect {
                    top,
                    left: 1,
                    rows: height.max(3) as u16,
                    cols,
                });
                top += height.max(3) as u16;
            }
        } else {
            let mut left: u16 = 1;
            let mut used: u32 = 0;
            for (at, index) in members.iter().enumerate() {
                let weight = self.panes[*index].weight.max(1) as u32;
                let width = if at + 1 == members.len() {
                    (cols as u32).saturating_sub(used)
                } else {
                    (cols as u32 * weight) / total
                };
                used += width;
                rects.push(Rect {
                    top: 1,
                    left,
                    rows,
                    cols: width.max(6) as u16,
                });
                left += width as u16;
            }
        }
        rects
    }

    /// draw answers the whole screen as the escape sequences that draw it.
    pub fn draw(&self) -> String {
        let cols = self.cols.max(20) as usize;
        let rows = self.rows.max(6) as usize;
        let area_rows = rows.saturating_sub(3) as u16;
        let mut out = String::new();
        out.push_str("\x1b[?25l");
        put(&mut out, 1, 1, &clip(&self.tab_bar(), cols));
        let rects = self.rects(self.cols.max(20), area_rows);
        let members = self.tab_panes();
        for (at, rect) in rects.iter().enumerate() {
            let index = members[at];
            let focused = index == self.focused;
            let lines = self.pane_lines(index, rect, focused);
            for (row, text) in lines.iter().enumerate() {
                put(&mut out, rect.top + row as u16, rect.left, text);
            }
        }
        put(&mut out, rows as u16 - 1, 1, &clip(&self.events_line(), cols));
        put(&mut out, rows as u16, 1, &clip(&self.mode_line(), cols));
        if let Some(panel) = &self.panel {
            self.draw_panel(&mut out, panel, rows);
        }
        out.push_str("\x1b[0m");
        out
    }

    /// draw_panel draws the box that lies over the panes.
    fn draw_panel(&self, out: &mut String, panel: &Panel, rows: usize) {
        let width = panel
            .lines
            .iter()
            .map(|line| line.chars().count())
            .max()
            .unwrap_or(20)
            .max(panel.title.chars().count() + 4)
            .min(self.cols.max(20) as usize - 2);
        let height = panel.lines.len() + 2;
        let top = 2u16;
        let left = 2u16;
        let mut edge = format!("+-- {} ", panel.title);
        while edge.chars().count() + 1 < width {
            edge.push('-');
        }
        edge.push('+');
        put(out, top, left, &edge);
        for (at, line) in panel.lines.iter().enumerate() {
            put(
                out,
                top + 1 + at as u16,
                left,
                &format!("|{}|", clip(line, width.saturating_sub(2))),
            );
        }
        put(out, top + height as u16, left, &format!("+{}+", "-".repeat(width - 2)));
        let _ = rows;
    }

    /// events_line answers the strip that says what just happened: the last
    /// event, and how many are waiting behind it.
    fn events_line(&self) -> String {
        match self.events.last() {
            Some(last) => format!("{} ({} events)", last, self.events.len()),
            None => "nothing has happened yet".to_string(),
        }
    }

    /// tab_bar answers the line that names the tabs and marks the one the
    /// owner stands in.
    fn tab_bar(&self) -> String {
        if self.tabs.is_empty() {
            return "[no tabs]".to_string();
        }
        let mut line = String::new();
        for (at, tab) in self.tabs.iter().enumerate() {
            if at > 0 {
                line.push(' ');
            }
            if at == self.tab {
                line.push('[');
                line.push_str(tab);
                line.push(']');
            } else {
                line.push_str(tab);
            }
        }
        line
    }

    /// pane_lines answers the lines of one pane: its frame, its name, and
    /// what its program said.
    fn pane_lines(&self, index: usize, rect: &Rect, focused: bool) -> Vec<String> {
        let inner = rect.cols.saturating_sub(2) as usize;
        let height = rect.rows.saturating_sub(2) as usize;
        let mut lines: Vec<String> = Vec::new();
        let name = format!("{} ", self.panes[index].name);
        let mark = if focused { "*" } else { " " };
        let mut top = format!("+{}{}", mark, name);
        while top.chars().count() + 1 < rect.cols as usize {
            top.push('-');
        }
        top.push('+');
        lines.push(top);
        let pane = &self.panes[index];
        let start = pane.lines.len().saturating_sub(height);
        for line in pane.lines[start..].iter() {
            lines.push(format!("|{}|", clip(line, inner)));
        }
        while lines.len() < height + 1 {
            lines.push(format!("|{}|", " ".repeat(inner)));
        }
        lines.push(format!("+{}+", "-".repeat(inner)));
        lines
    }

    /// mode_line answers the line at the bottom: the mode, the tab, the
    /// focused pane, the size of the window, and the keys that are free now.
    fn mode_line(&self) -> String {
        if self.mode == Mode::Command {
            return format!(":{}", self.command);
        }
        let mut line = format!(
            "-- {} -- tab {} -- pane {} -- {}x{} -- ",
            self.mode_name(),
            self.focused_tab(),
            self.focused_pane(),
            self.cols,
            self.rows
        );
        match self.mode {
            Mode::Visual => {
                let pending = self.keymap.pending_keys();
                if pending.is_empty() {
                    line.push_str("Space:keys  i:type  ::command  q:leave");
                } else {
                    line.push_str(&format!("{} …", pending));
                }
            }
            Mode::Insert => line.push_str("esc:visual"),
            Mode::Command => line.push_str(""),
            Mode::Explorer => line.push_str("esc:back  any key of the map"),
        }
        if !self.message.is_empty() {
            line.push_str("  ");
            line.push_str(&self.message);
        }
        line
    }

    /// mode_name answers the name of the mode, the way the mode line shows it.
    fn mode_name(&self) -> &'static str {
        match self.mode {
            Mode::Visual => "VISUAL",
            Mode::Insert => "INSERT",
            Mode::Command => "COMMAND",
            Mode::Explorer => "KEYS",
        }
    }

    /// key reads the keys the owner pressed and answers what the client must
    /// do about them.
    ///
    /// A chunk of keys is read one at a time, so a key that changes the mode
    /// leaves the rest of the chunk to the new mode. Every key that means
    /// something is answered, in order: a paste of text is a paste of text,
    /// not the last byte of it.
    pub fn key(&mut self, bytes: &[u8]) -> Vec<Action> {
        let mut actions: Vec<Action> = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            match self.mode {
                Mode::Insert => {
                    // The keys belong to the program in the pane: the whole
                    // run of them goes as it was typed. A lone Escape leaves
                    // Insert, and it is not sent on.
                    let mut end = at;
                    while end < bytes.len() {
                        if bytes[end] == ESCAPE {
                            if end + 1 < bytes.len() && bytes[end + 1] == b'[' {
                                // an arrow key: it belongs to the program
                                end += 3;
                                continue;
                            }
                            break;
                        }
                        end += 1;
                    }
                    if end > at {
                        actions.push(Action::Send(bytes[at..end].to_vec()));
                        at = end;
                        continue;
                    }
                    self.mode = Mode::Visual;
                    self.message = "visual".to_string();
                    at += 1;
                }
                Mode::Command => {
                    let now = self.command_key(&bytes[at..]);
                    if !matches!(now, Action::Nothing) {
                        actions.push(now);
                    }
                    at = bytes.len();
                }
                Mode::Visual | Mode::Explorer => {
                    let now = self.visual_key(bytes[at]);
                    if !matches!(now, Action::Nothing) {
                        actions.push(now);
                    }
                    at += 1;
                }
            }
        }
        actions
    }

    /// visual_key reads one key in VISUAL or in the EXPLORER, and answers what
    /// the client must do.
    fn visual_key(&mut self, key: u8) -> Action {
        let mode = self.mode;
        match self.keymap.resolve(mode, key) {
            Resolution::Command(command) => {
                if mode == Mode::Explorer {
                    // A command run from the explorer leaves it, and the
                    // owner is back where the command belongs.
                    self.close_panel();
                }
                self.run(command)
            }
            Resolution::Map(context) => {
                if mode == Mode::Explorer {
                    self.keymap.open_map(context);
                    self.show_explorer();
                    return Action::Nothing;
                }
                // In VISUAL a group opens and waits for the next key.
                Action::Nothing
            }
            Resolution::Pending => Action::Nothing,
            Resolution::Pass => Action::Nothing,
            Resolution::Ignore => {
                if mode == Mode::Visual && key < 0x20 && key != ESCAPE {
                    // A Control key belongs to the program in the pane: the
                    // owner must still be able to interrupt it.
                    return Action::Send(vec![key]);
                }
                if mode == Mode::Explorer && key == ESCAPE {
                    self.close_panel();
                    self.mode = Mode::Visual;
                }
                Action::Nothing
            }
        }
    }

    /// command_key reads a key in the COMMAND line: the words are the
    /// multiplexer's.
    fn command_key(&mut self, bytes: &[u8]) -> Action {
        for byte in bytes {
            match *byte {
                ESCAPE => {
                    self.mode = Mode::Visual;
                    self.command.clear();
                    return Action::Nothing;
                }
                ENTER => {
                    let said = self.command.trim().to_string();
                    self.command.clear();
                    self.mode = Mode::Visual;
                    return self.run_command(&said);
                }
                BACKSPACE => {
                    self.command.pop();
                }
                byte if byte >= 0x20 => {
                    if self.command.chars().count() < 200 {
                        self.command.push(byte as char);
                    }
                }
                _ => {}
            }
        }
        Action::Nothing
    }

    /// run does what the command says, and answers what the client must do
    /// with the holder. The command does not know which key asked for it.
    fn run(&mut self, command: Command) -> Action {
        self.message = String::new();
        match command {
            Command::Nothing => Action::Nothing,
            Command::EnterInsert => {
                self.mode = Mode::Insert;
                self.message = "insert".to_string();
                Action::Nothing
            }
            Command::OpenCommandLine => {
                self.mode = Mode::Command;
                self.command.clear();
                Action::Nothing
            }
            Command::OpenExplorer => {
                self.mode = Mode::Explorer;
                self.keymap.open_map(Context::Root);
                self.show_explorer();
                Action::Nothing
            }
            Command::CloseExplorer => {
                self.close_panel();
                self.mode = Mode::Visual;
                Action::Nothing
            }
            Command::Detach => Action::Quit,
            Command::TabAdd => {
                let name = format!("tab-{}", self.tabs.len() + 1);
                let tab = name.clone();
                self.open_pane(name, "/bin/sh".to_string(), tab)
            }
            Command::TabClose => {
                let tab = self.focused_tab();
                Action::Request(json!({
                    "op": "close",
                    "kind": "tab",
                    "name": tab
                }))
            }
            Command::TabRename => {
                self.mode = Mode::Command;
                self.command = ":tab rename ".to_string();
                Action::Nothing
            }
            Command::TabNext => {
                self.move_tab(1);
                Action::Nothing
            }
            Command::TabPrevious => {
                self.move_tab(-1);
                Action::Nothing
            }
            Command::PaneAdd => {
                let name = format!("pane-{}", self.panes.len() + 1);
                let tab = self.focused_tab();
                self.open_pane(name, "/bin/sh".to_string(), tab)
            }
            Command::PaneClose => {
                let pane = self.focused_pane();
                Action::Request(json!({
                    "op": "close",
                    "kind": "pane",
                    "name": pane
                }))
            }
            Command::PaneRename => {
                self.mode = Mode::Command;
                self.command = ":pane rename ".to_string();
                Action::Nothing
            }
            Command::PaneNext => {
                self.move_focus(1);
                Action::Nothing
            }
            Command::PanePrevious => {
                self.move_focus(-1);
                Action::Nothing
            }
            Command::OpenAgent => {
                let program = self.agent_program.clone();
                self.open_pane("agent".to_string(), program, self.focused_tab())
            }
            Command::OpenEditor => {
                let program = self.editor_program.clone();
                self.open_pane("editor".to_string(), program, self.focused_tab())
            }
            Command::ShowRecords => {
                self.show_records();
                Action::Nothing
            }
            Command::ShowSessions => {
                self.show_sessions();
                Action::Nothing
            }
        }
    }

    /// open_pane asks the holder for a pane with a program in it.
    fn open_pane(&mut self, name: String, program: String, tab: String) -> Action {
        Action::Request(json!({
            "op": "open",
            "name": name,
            "program": program,
            "tab": tab
        }))
    }

    /// run_command runs the words the owner typed on the command line.
    fn run_command(&mut self, said: &str) -> Action {
        let words: Vec<&str> = said.split_whitespace().collect();
        self.message = String::new();
        match words.as_slice() {
            [] => Action::Nothing,
            ["q"] | ["quit"] => Action::Quit,
            ["help"] => {
                self.mode = Mode::Explorer;
                self.keymap.open_map(Context::Root);
                self.show_explorer();
                Action::Nothing
            }
            ["mode", "visual"] => {
                self.mode = Mode::Visual;
                Action::Nothing
            }
            ["mode", "insert"] => {
                self.mode = Mode::Insert;
                Action::Nothing
            }
            ["tab", "new"] => self.run(Command::TabAdd),
            ["tab", "close"] => self.run(Command::TabClose),
            ["tab", "rename", name] => Action::Request(json!({
                "op": "rename",
                "kind": "tab",
                "name": self.focused_tab(),
                "to": name
            })),
            ["tab", "next"] => self.run(Command::TabNext),
            ["tab", "previous"] => self.run(Command::TabPrevious),
            ["pane", "new"] => self.run(Command::PaneAdd),
            ["pane", "close"] => self.run(Command::PaneClose),
            ["pane", "rename", name] => Action::Request(json!({
                "op": "rename",
                "kind": "pane",
                "name": self.focused_pane(),
                "to": name
            })),
            ["pane", "next"] => self.run(Command::PaneNext),
            ["pane", "previous"] => self.run(Command::PanePrevious),
            ["agent"] => self.run(Command::OpenAgent),
            ["editor"] => self.run(Command::OpenEditor),
            ["records"] => self.run(Command::ShowRecords),
            ["sessions"] => self.run(Command::ShowSessions),
            other => {
                self.message = format!("{} is not a command", other.join(" "));
                Action::Nothing
            }
        }
    }

    /// show_explorer fills the panel with the keys of the map the explorer is
    /// showing. The panel is made of the keymap's own table, so it cannot
    /// fall behind it.
    fn show_explorer(&mut self) {
        let map = self.keymap.explorer_map();
        let state = self.state();
        let mut lines: Vec<String> = Vec::new();
        for binding in bindings(map) {
            let mut line = format!("  {:<8} {}", binding.keys, binding.about);
            if binding.is_map() {
                line.push_str("  → a group");
            }
            if !binding.available(&state) {
                line.push_str("  (not now)");
            }
            lines.push(line);
        }
        lines.push(String::new());
        lines.push("  Escape goes back one level".to_string());
        let pending = self.keymap.pending_keys();
        if !pending.is_empty() {
            lines.push(format!("  typing: {}", pending));
        }
        self.panel = Some(Panel {
            title: format!("the keymap — {}", map.title()),
            lines,
        });
    }

    /// show_records fills the panel with the records of this session.
    fn show_records(&mut self) {
        let mut lines: Vec<String> = Vec::new();
        for event in self.events.iter().rev().take(20).rev() {
            lines.push(format!("  {}", event));
        }
        if lines.is_empty() {
            lines.push("  nothing has happened yet".to_string());
        }
        self.panel = Some(Panel {
            title: "the records".to_string(),
            lines,
        });
    }

    /// show_sessions fills the panel with the sessions this multiplexer knows.
    fn show_sessions(&mut self) {
        let mut lines: Vec<String> = Vec::new();
        lines.push(format!("  this one: {}", self.focused_tab()));
        self.panel = Some(Panel {
            title: "the sessions".to_string(),
            lines,
        });
    }

    /// close_panel closes the panel over the panes.
    fn close_panel(&mut self) {
        self.panel = None;
    }

    /// move_focus moves the focus to the next or the previous pane of the
    /// current tab.
    fn move_focus(&mut self, step: i32) {
        let members = self.tab_panes();
        if members.is_empty() {
            return;
        }
        let at = members
            .iter()
            .position(|index| *index == self.focused)
            .unwrap_or(0) as i32;
        let count = members.len() as i32;
        let next = (at + step).rem_euclid(count) as usize;
        self.focused = members[next];
    }

    /// move_tab moves to the next or the previous tab.
    fn move_tab(&mut self, step: i32) {
        if self.tabs.is_empty() {
            return;
        }
        let count = self.tabs.len() as i32;
        let next = (self.tab as i32 + step).rem_euclid(count) as usize;
        self.tab = next;
        let members = self.tab_panes();
        if !members.is_empty() {
            self.focused = members[0];
        }
    }
}

/// clip answers the text with no more than width characters, and no more
/// than one line.
fn clip(text: &str, width: usize) -> String {
    text.chars().take(width).collect()
}

/// put answers the escape sequence that puts one line of text at one place
/// on the terminal.
fn put(out: &mut String, row: u16, left: u16, text: &str) {
    out.push_str(&format!("\x1b[{};{}H", row, left));
    out.push_str(text);
    out.push_str("\x1b[K");
}

/// session is the screen's own life: it attaches to the holder, draws the
/// panes, and answers the keys until the owner leaves.
pub fn session(
    fd: libc::c_int,
    client_name: &str,
    agent_program: String,
    editor_program: String,
) -> Result<(), String> {
    let saved = tty::save_termios(libc::STDIN_FILENO).ok();
    let _ = tty::make_raw(libc::STDIN_FILENO);
    let mut screen = Screen::empty(agent_program, editor_program);
    wire::ask(fd, &json!({ "op": "state", "client": client_name }))?;
    wire::ask(
        fd,
        &json!({
            "op": "attach",
            "client": client_name,
            "event-contract": crate::EVENT_CONTRACT,
            "holder-contract": crate::HOLDER_CONTRACT
        }),
    )?;

    let mut pending = String::new();
    let mut out = std::io::stdout();
    let mut leave = false;
    while !leave {
        // The window: the terminal's size is the session's size, and the
        // holder tells every pane — the shells and the editors alike.
        let size = tty::window_size(libc::STDOUT_FILENO).unwrap_or((80, 24));
        if size.0 != screen.cols || size.1 != screen.rows {
            screen.cols = size.0;
            screen.rows = size.1;
            wire::ask(
                fd,
                &json!({
                    "op": "resize",
                    "client": client_name,
                    "cols": size.0,
                    "rows": size.1
                }),
            )?;
        }

        // The keys are only read once the screen knows the panes: a key that
        // arrives before the state would go to a pane the screen has not met.
        let ready = !screen.panes.is_empty();
        let mut fds = vec![libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        }];
        if ready {
            fds.push(libc::pollfd {
                fd: libc::STDIN_FILENO,
                events: libc::POLLIN,
                revents: 0,
            });
        }
        let ready_poll = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready_poll < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            break;
        }

        if fds[0].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let mut buffer = [0u8; 8192];
            let got = wire::read(fd, &mut buffer)?;
            if got == 0 {
                break;
            }
            pending.push_str(&String::from_utf8_lossy(&buffer[..got]));
            while let Some(at) = pending.find('\n') {
                let line = pending[..at].trim().to_string();
                pending = pending[at + 1..].to_string();
                if line.is_empty() {
                    continue;
                }
                take_record(&mut screen, &line);
            }
        }

        // A pipe that is at its end says POLLHUP, not POLLIN: the end of the
        // keys is an event too, and the client must hear it.
        if fds.len() > 1 && fds[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let mut buffer = [0u8; 1024];
            let got = wire::read(libc::STDIN_FILENO, &mut buffer)?;
            if got == 0 {
                break;
            }
            for action in screen.key(&buffer[..got]) {
                match action {
                    Action::Nothing => {}
                    Action::Send(bytes) => {
                        let text = String::from_utf8_lossy(&bytes).to_string();
                        wire::ask(
                            fd,
                            &json!({
                                "op": "send",
                                "client": client_name,
                                "pane": screen.focused_pane(),
                                "data": text
                            }),
                        )?;
                    }
                    Action::Request(request) => {
                        let mut request = request;
                        request["client"] = Value::from(client_name);
                        wire::ask(fd, &request)?;
                    }
                    Action::Quit => leave = true,
                }
            }
        }

        let drawing = screen.draw();
        let _ = out.write_all(drawing.as_bytes());
        let _ = out.flush();
    }

    out.write_all(b"\x1b[?25h\x1b[0m\n").ok();
    let _ = out.flush();
    if let Some(settings) = saved {
        let _ = tty::restore_termios(libc::STDIN_FILENO, &settings);
    }
    Ok(())
}

/// take_record reads one record from the holder into the screen.
///
/// Every record is shown: the program's output goes into the pane it came
/// from, and the event itself goes into the events strip, so nothing that
/// happened is silent (rule 01: nothing important is silent).
fn take_record(screen: &mut Screen, line: &str) {
    let record: Value = match serde_json::from_str(line) {
        Ok(found) => found,
        Err(_) => return,
    };
    let kind = record.get("kind").and_then(|value| value.as_str()).unwrap_or("");
    let who = record.get("who").and_then(|value| value.as_str()).unwrap_or("");
    let what = record.get("what").and_then(|value| value.as_str()).unwrap_or("");
    let why = record.get("why").and_then(|value| value.as_str()).unwrap_or("");
    screen.events.push(format!("{} {}: {} — {}", kind, who, what, why));
    if screen.events.len() > 50 {
        let extra = screen.events.len() - 50;
        screen.events.drain(0..extra);
    }
    if kind == "progress" {
        let text = record
            .get("outputs")
            .and_then(|outputs| outputs.get("text"))
            .and_then(|value| value.as_str())
            .unwrap_or("");
        screen.push_text(who, text);
        return;
    }
    if who == "holder" {
        screen.take_state(&record);
    }
}
