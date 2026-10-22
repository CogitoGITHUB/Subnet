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
use super::select::Selection;
use super::tty;
use super::wire;
use super::config::{ConfigFile, Reload};
use super::control;
use super::geometry;

/// ESCAPE leaves Insert, and cancels a sequence or the explorer.
const ESCAPE: u8 = 0x1b;
/// ENTER ends a command line.
const ENTER: u8 = 0x0d;
/// BACKSPACE takes the last character off the command line.
const BACKSPACE: u8 = 0x7f;
/// RESERVED_PREFIX is the escape hatch: the multiplexer keeps it in every
/// mode, so the owner can reach the multiplexer's own keys while a program
/// in the focused pane has the keyboard. Every other key in Insert belongs
/// to that program (rule 06).
const RESERVED_PREFIX: u8 = 0x02;
/// KEPT is how many lines of a pane's output the screen remembers.
const KEPT: usize = 400;

/// RING_KEPT is how many copies the multiplexer's own ring holds. The
/// ring is a small buffer: the newest copy is the first one.
const RING_KEPT: usize = 20;

/// VIEW_LINES is how many lines of a pane the agent's view carries: the
/// newest ones, each with the number the agent names it by.
const VIEW_LINES: usize = 40;

/// Action is what the client does with the holder after a key.
pub enum Action {
    Nothing,
    /// Send puts the bytes into the focused pane's own program.
    Send(Vec<u8>),
    /// Request asks the holder to do one thing.
    Request(Value),
    /// Quit leaves the multiplexer; the session goes on.
    Quit,
    /// AskEditor asks the editor what it owns, over the editor's own MCP
    /// server: the answer comes back as the editor's own words.
    AskEditor,
}

/// PaneView is one pane as the screen sees it: its name, its tab, how much
/// of the layout it wants, and what its program said.
pub struct PaneView {
    pub name: String,
    pub tab: String,
    pub weight: u16,
    pub lines: Vec<String>,
    /// scroll is how many lines the view is back from the tail of the
    /// pane's lines. Zero is the tail: the newest words. The page keys
    /// move it, and the view shows the page the owner scrolled to.
    pub scroll: usize,
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
    /// select is the selection: the point, the mark and the region.
    pub select: Selection,
    /// ring is the multiplexer's own ring: what was copied, newest first.
    pub ring: Vec<String>,
    keymap: Keymap,
    panel: Option<Panel>,
    /// git is what the shared layer answered, and git_want is which view
    /// was asked for.
    git: Option<Value>,
    git_want: String,
    /// workspace is what the shared engine answered, and workspace_view is
    /// which view was asked for.
    workspace: Option<Value>,
    workspace_view: String,
    /// workspace_name is the workspace this session works on, and
    /// project_name is the project the context stands on. The mode line
    /// names both.
    workspace_name: String,
    project_name: String,
    /// level is how much of the screen's own furniture is drawn. Level 1
    /// is the mode row and the tab bar; level 2 adds the specifics and
    /// the events; level 3 adds the hints. Level 0 draws no furniture at
    /// all: the panes take the whole screen, and the owner asked for
    /// that.
    level: u8,
    /// shows_tab_bar says whether the tab bar is drawn at level 1 and
    /// above. The config asks for it; level 0 hides it whatever the
    /// config says.
    shows_tab_bar: bool,
    /// reserved says that the owner pressed the reserved prefix: the next
    /// key is the multiplexer's own, whatever mode stands.
    reserved: bool,
    /// editor_mcp is the command that starts the editor's own MCP server:
    /// the program and what it runs. It is the seam the multiplexer asks
    /// the editor through.
    editor_mcp: Vec<String>,
    /// pending is the agent's request that waits for the state: the answer
    /// the agent gets is the state as it stands, not the state as it was.
    pending: Option<String>,
    /// fresh says the state arrived: the pending request may be answered.
    fresh: bool,
}

impl Screen {
    /// empty is a screen with nothing on it yet: the holder's state fills it
    /// in as soon as the state arrives.
    pub fn empty(
        agent_program: String,
        editor_program: String,
        editor_mcp: Vec<String>,
    ) -> Screen {
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
            reserved: false,
            select: Selection::new(),
            ring: Vec::new(),
            keymap: Keymap::empty(),
            panel: None,
            git: None,
            git_want: String::new(),
            workspace: None,
            workspace_view: String::new(),
            workspace_name: String::new(),
            project_name: String::new(),
            level: 2,
            shows_tab_bar: true,
            editor_mcp,
            pending: None,
            fresh: false,
        }
    }

    /// set_level is the level the config asks for: how much of the screen's
    /// own furniture is drawn. A value above 3 is not a level, so it is taken
    /// as 3 rather than refused.
    pub fn set_level(&mut self, level: u8) {
        self.level = level.min(3);
    }

    /// level answers how much furniture the screen draws now.
    pub fn level(&self) -> u8 {
        self.level
    }

    /// set_tab_bar says whether the tab bar is drawn at level 1 and above.
    pub fn set_tab_bar(&mut self, on: bool) {
        self.shows_tab_bar = on;
    }

    /// tab_bar_on answers whether the tab bar is drawn at level 1 and above.
    pub fn tab_bar_on(&self) -> bool {
        self.shows_tab_bar
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
        // The state arrived: a request that waits for it may be answered.
        self.fresh = true;
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
                let mut lines = self
                    .panes
                    .iter()
                    .find(|held| held.name == name)
                    .map(|held| held.lines.clone())
                    .unwrap_or_default();
                if lines.is_empty() {
                    // The pane's recent words come with the state: a
                    // client that attaches sees the panes as they are,
                    // and not an empty frame.
                    if let Some(text) = pane.get("text").and_then(|value| value.as_str()) {
                        for line in text.lines() {
                            lines.push(line.to_string());
                        }
                    }
                }
                // The view of a pane keeps its place: the state arrives
                // again and again, and a pane that jumped back to the tail
                // every time would lose the page the owner scrolled to.
                let scroll = self
                    .panes
                    .iter()
                    .find(|held| held.name == name)
                    .map(|held| held.scroll)
                    .unwrap_or(0);
                panes.push(PaneView {
                    name,
                    tab,
                    weight,
                    lines,
                    scroll,
                });
            }
        }
        // The workspace comes with the state: the mode line names the
        // workspace and the project as soon as the client attaches.
        if let Some(workspace) = outputs.get("workspace") {
            self.take_workspace_data(workspace);
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
    pub fn focused_pane(&self) -> String {
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

    /// rects answers where each pane of the current tab sits on the
    /// terminal. It is the holder's own geometry, so the drawing here and
    /// the sizes the programs get cannot drift apart.
    fn rects(&self, cols: u16, rows: u16, top: u16) -> Vec<geometry::Rect> {
        let members = self.tab_panes();
        let weights: Vec<u16> = members
            .iter()
            .map(|at| self.panes[*at].weight.max(1))
            .collect();
        geometry::rects(&self.direction, &weights, cols, rows, top)
    }

    /// draw answers the whole screen as the escape sequences that draw it.
    pub fn draw(&self) -> String {
        let cols = self.cols.max(20) as usize;
        let rows = self.rows.max(6) as usize;
        // The screen's own furniture takes rows from the programs: the
        // level says how much of it there is, and level 0 leaves the
        // whole screen to the panes.
        let (top, area_rows) = self.area();
        let status = self.status_rows();
        let bar = self.level >= 1 && self.shows_tab_bar;
        let mut out = String::new();
        out.push_str("\x1b[?25l");
        if bar {
            put(&mut out, 1, 1, &clip(&self.tab_bar(), cols));
        }
        let rects = self.rects(self.cols.max(20), area_rows, top);
        let members = self.tab_panes();
        for (at, rect) in rects.iter().enumerate() {
            let index = members[at];
            let focused = index == self.focused;
            let lines = self.pane_lines(index, rect, focused);
            for (row, text) in lines.iter().enumerate() {
                put(&mut out, rect.top + row as u16, rect.left, text);
            }
        }
        // The rows of the screen's own furniture sit at the bottom, and
        // the mode row is the last of them.
        let first = rows.saturating_sub(status.len()) as u16 + 1;
        for (at, line) in status.iter().enumerate() {
            put(&mut out, first + at as u16, 1, &clip(line, cols));
        }
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

    /// window answers the lines of one pane that the screen shows: the tail
    /// of the pane's words, or the page the owner scrolled to.
    ///
    /// The drawing and the pick read this one window, so a line that is on
    /// the screen is a line that can be picked, and a line that is not on
    /// the screen cannot be picked: it cannot be seen.
    fn window(&self, index: usize, height: usize) -> Vec<String> {
        let pane = match self.panes.get(index) {
            Some(pane) => pane,
            None => return Vec::new(),
        };
        let end = pane.lines.len().saturating_sub(pane.scroll);
        let start = end.saturating_sub(height);
        pane.lines[start..end].to_vec()
    }

    /// focus_height answers how many lines the focused pane shows.
    fn focus_height(&self) -> usize {
        let cols = self.cols.max(20);
        let (top, area_rows) = self.area();
        let rects = self.rects(cols, area_rows, top);
        let members = self.tab_panes();
        let at = match members.iter().position(|index| *index == self.focused) {
            Some(at) => at,
            None => return 0,
        };
        match rects.get(at) {
            Some(rect) => rect.rows.saturating_sub(2) as usize,
            None => 0,
        }
    }

    /// scroll_view moves the view of the focused pane by one page: a page is
    /// the height of that pane, and the view stops at the oldest page there
    /// is.
    ///
    /// The wheel is refused (rule 13): there is no mouse in this program,
    /// so the scroll is a key too, and the page keys are that key. The
    /// answer says whether the view moved: a scroll that could not happen
    /// is said, and not hidden.
    fn scroll_view(&mut self, up: bool) -> bool {
        let height = self.focus_height();
        if height == 0 {
            return false;
        }
        let index = self.focused;
        let (total, current) = match self.panes.get(index) {
            Some(pane) => (pane.lines.len(), pane.scroll),
            None => return false,
        };
        let most = total.saturating_sub(height);
        let next = if up {
            current.saturating_add(height).min(most)
        } else {
            current.saturating_sub(height)
        };
        if let Some(pane) = self.panes.get_mut(index) {
            pane.scroll = next;
        }
        next != current
    }

    /// scroll_distance answers how far the focused pane's view is from the
    /// tail of its words.
    fn scroll_distance(&self) -> usize {
        self.panes
            .get(self.focused)
            .map(|pane| pane.scroll)
            .unwrap_or(0)
    }

    /// pane_lines answers the lines of one pane: its frame, its name, and
    /// what its program said.
    fn pane_lines(&self, index: usize, rect: &geometry::Rect, focused: bool) -> Vec<String> {
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
        let visible = self.window(index, height);
        // In the selection the region is shown in reverse video: the text
        // under the keys is the text that is selected.
        let visible = if focused && self.mode == Mode::Select {
            self.select.marked(&visible)
        } else {
            visible
        };
        for line in visible.iter() {
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
        // The message the client answers with stands next to the mode:
        // the row is cut at the end, so what the owner must read is at
        // the front.
        let mut line = format!("-- {} L{} -- ", self.mode_name(), self.level);
        if !self.workspace_name.is_empty() {
            line.push_str(&format!("ws:{} ", self.workspace_name));
            if !self.project_name.is_empty() {
                line.push_str(&format!("pr:{} ", self.project_name));
            }
            line.push_str("-- ");
        }
        if !self.message.is_empty() {
            line.push_str(&self.message);
            line.push_str(" -- ");
        }
        line.trim_end().to_string()
    }

    /// specifics_line answers the row that says where the owner stands in
    /// the session: the tab, the focused pane and the window size.
    fn specifics_line(&self) -> String {
        format!(
            "tab {} -- pane {} -- {}x{}",
            self.focused_tab(),
            self.focused_pane(),
            self.cols,
            self.rows
        )
    }

    /// hints_line answers the row that says what the keys do in this mode.
    fn hints_line(&self) -> String {
        match self.mode {
            Mode::Visual => {
                let pending = self.keymap.pending_keys();
                if pending.is_empty() {
                    "Space:keys  i:type  ::command  l:less  L:more  pg:page  q:leave".to_string()
                } else {
                    format!("{} …", pending)
                }
            }
            Mode::Insert => "esc:visual".to_string(),
            Mode::Command => String::new(),
            Mode::Explorer => "esc:back  any key of the map".to_string(),
            Mode::Select => "m:mark  y:copy  s:send  p o:agent  pg:page  esc:leave".to_string(),
        }
    }

    /// area answers where the panes stand: the row they start at, and how
    /// many rows they have. The screen's own furniture takes the rest, and
    /// the level says how much furniture that is.
    fn area(&self) -> (u16, u16) {
        let rows = self.rows.max(6);
        let bar = self.level >= 1 && self.shows_tab_bar;
        let top = if bar { 2 } else { 1 };
        let furniture = self.status_rows().len() + if bar { 1 } else { 0 };
        (top, rows.saturating_sub(furniture as u16))
    }

    /// status_rows answers the screen's own rows at the bottom, from the
    /// top of the block down: the events, the specifics, the hints and the
    /// mode row. The level says which of them are there, and the mode row
    /// is the last one, so it is the row nearest the owner's hands.
    fn status_rows(&self) -> Vec<String> {
        let mut rows: Vec<String> = Vec::new();
        if self.level >= 2 {
            rows.push(self.events_line());
            rows.push(self.specifics_line());
        }
        if self.level >= 3 {
            rows.push(self.hints_line());
        }
        if self.level >= 1 {
            rows.push(self.mode_line());
        }
        rows
    }

    /// mode_name answers the name of the mode, the way the mode line shows it.
    fn mode_name(&self) -> &'static str {
        match self.mode {
            Mode::Visual => "VISUAL",
            Mode::Insert => "INSERT",
            Mode::Command => "COMMAND",
            Mode::Explorer => "KEYS",
            Mode::Select => "SELECT",
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
            // The reserved prefix is the multiplexer's own in every mode:
            // the next key is read in the root map, whatever stands.
            if self.reserved {
                self.reserved = false;
                let now = self.reserved_key(bytes[at]);
                if !matches!(now, Action::Nothing) {
                    actions.push(now);
                }
                at += 1;
                continue;
            }
            match self.mode {
                Mode::Insert => {
                    if bytes[at] == RESERVED_PREFIX {
                        self.reserved = true;
                        at += 1;
                        continue;
                    }
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
                        if bytes[end] == RESERVED_PREFIX {
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
                    // One key at a time: the enter key ends the command
                    // line, and the keys after it belong to the screen
                    // again.
                    let now = self.command_key(bytes[at]);
                    if !matches!(now, Action::Nothing) {
                        actions.push(now);
                    }
                    at += 1;
                }
                Mode::Select => {
                    // The escape stands alone or it begins an arrow key:
                    // the byte stream knows that, and the map does not.
                    let arrow = bytes[at] == ESCAPE
                        && at + 2 < bytes.len()
                        && bytes[at + 1] == b'[';
                    if bytes[at] == ESCAPE && !arrow {
                        // The escape leaves the selection and does nothing
                        // else: no text is copied, no bundle is sent and
                        // no pane opens.
                        self.mode = Mode::Visual;
                        self.message =
                            "the selection is closed: nothing was copied and nothing was sent"
                                .to_string();
                        at += 1;
                        continue;
                    }
                    let end = if arrow { at + 3 } else { at + 1 };
                    for byte in bytes[at..end].iter() {
                        let now = self.select_key(*byte);
                        if !matches!(now, Action::Nothing) {
                            actions.push(now);
                        }
                    }
                    at = end;
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

    /// reserved_key reads one key that came after the reserved prefix: it is
    /// the multiplexer's own, read in the root map whatever mode stands, so
    /// the owner reaches the multiplexer from inside a program that has the
    /// keyboard.
    fn reserved_key(&mut self, key: u8) -> Action {
        match self.keymap.resolve(Mode::Visual, key) {
            Resolution::Command(command) => self.run(command),
            Resolution::Map(context) => {
                self.keymap.open_map(context);
                self.show_explorer();
                Action::Nothing
            }
            Resolution::Pending => Action::Nothing,
            Resolution::Pass => Action::Nothing,
            Resolution::Ignore => Action::Nothing,
        }
    }

    /// select_key reads one key in the SELECTION and answers what the
    /// client must do.
    ///
    /// The selection is an overlay on the visual mode: the mode line
    /// says which mode stands, and the escape leaves the selection and
    /// does nothing else.
    fn select_key(&mut self, key: u8) -> Action {
        match self.keymap.resolve(Mode::Select, key) {
            Resolution::Command(command) => self.select_command(command),
            Resolution::Map(_) => Action::Nothing,
            Resolution::Pending => Action::Nothing,
            Resolution::Pass => Action::Nothing,
            Resolution::Ignore => Action::Nothing,
        }
    }

    /// command_key reads a key in the COMMAND line: the words are the
    /// multiplexer's.
    fn command_key(&mut self, byte: u8) -> Action {
        match byte {
            ESCAPE => {
                self.mode = Mode::Visual;
                self.command.clear();
                Action::Nothing
            }
            // The enter key, however it arrives: a terminal sends a
            // carriage return, a pipe sends a line feed.
            ENTER | b'\n' => {
                let said = self.command.trim().to_string();
                self.command.clear();
                self.mode = Mode::Visual;
                self.run_command(&said)
            }
            BACKSPACE => {
                self.command.pop();
                Action::Nothing
            }
            byte if byte >= 0x20 => {
                if self.command.chars().count() < 200 {
                    self.command.push(byte as char);
                }
                Action::Nothing
            }
            _ => Action::Nothing,
        }
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
                self.command = "tab rename ".to_string();
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
                self.command = "pane rename ".to_string();
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
            Command::PaneGrow => self.change_weight(1),
            Command::PaneShrink => self.change_weight(-1),
            Command::OpenAgent => self.open_agent(),
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
            Command::GitOverview => self.show_git("overview"),
            Command::GitChanged => self.show_git("changed"),
            Command::GitDiff => self.show_git("diff"),
            Command::GitHistory => self.show_git("history"),
            Command::GitBranches => self.show_git("branches"),
            Command::GitWorktrees => self.show_git("worktrees"),
            Command::LevelHide => {
                // One level less: at level 1 the mode row and the tab bar
                // go too, and the panes take the whole screen.
                self.level = self.level.saturating_sub(1);
                self.message = format!("the level: {}", self.level);
                Action::Nothing
            }
            Command::LevelShow => {
                self.level = (self.level + 1).min(3);
                self.message = format!("the level: {}", self.level);
                Action::Nothing
            }
            Command::PageUp => {
                // The wheel is refused: there is no mouse here, so the
                // scroll is a key, and this is that key.
                if self.scroll_view(true) {
                    self.message = format!(
                        "the view is one page up: {} lines from the tail",
                        self.scroll_distance()
                    );
                } else {
                    self.message = "the view is at the oldest page: it did not move".to_string();
                }
                Action::Nothing
            }
            Command::PageDown => {
                if self.scroll_view(false) {
                    self.message = format!(
                        "the view is one page down: {} lines from the tail",
                        self.scroll_distance()
                    );
                } else {
                    self.message = "the view is at the newest words: it did not move".to_string();
                }
                Action::Nothing
            }
            Command::WorkspaceList => self.show_workspace("list"),
            Command::WorkspaceContext => self.show_workspace("context"),
            Command::AskEditor => {
                // The editor is asked through its own server, and the ask
                // takes as long as the editor takes to start. The owner is
                // told that before the wait, never after it.
                self.message =
                    "the editor is being asked: its own server starts first, and that takes a while"
                        .to_string();
                Action::AskEditor
            }
            Command::WorkspaceOpen => {
                // The owner names the project, and the name follows in the
                // command line.
                self.mode = Mode::Command;
                self.command = "workspace open ".to_string();
                Action::Nothing
            }
            Command::EnterSelect => {
                self.mode = Mode::Select;
                self.select = Selection::new();
                self.message = "the selection is open on the focused pane".to_string();
                Action::Nothing
            }
            Command::SelectLeft
            | Command::SelectRight
            | Command::SelectUp
            | Command::SelectDown
            | Command::SelectWordLeft
            | Command::SelectWordRight
            | Command::SelectMark
            | Command::SelectPopMark
            | Command::SelectCopy
            | Command::SelectCopyLine
            | Command::SelectSend
            | Command::SelectAgentHere
            | Command::LeaveSelect => self.select_command(command),
        }
    }

    /// show_git asks the holder what Git says, and the answer fills the
    /// panel. The holder asks the shared layer, and the layer only reads:
    /// nothing here can change a repository.
    fn show_git(&mut self, want: &str) -> Action {
        self.git_want = want.to_string();
        self.message = format!("the git is being read: {}", want);
        Action::Request(json!({
            "op": "git",
            "what": want
        }))
    }

    /// show_workspace asks the holder what the shared workspace holds, and
    /// the answer fills the panel. The holder asks the engine, and the
    /// engine owns the workspaces, the projects and the context.
    fn show_workspace(&mut self, view: &str) -> Action {
        self.workspace_view = view.to_string();
        self.message = format!("the workspace is being read: {}", view);
        Action::Request(json!({
            "op": "workspace",
            "what": view
        }))
    }

    /// take_workspace reads the engine's answer and fills the panel with
    /// it.
    fn take_workspace(&mut self, record: &Value) {
        let data = match record
            .get("outputs")
            .and_then(|outputs| outputs.get("workspace"))
        {
            Some(data) => data.clone(),
            None => return,
        };
        self.take_workspace_data(&data);
        let lines = crate::workspace::lines(&self.workspace_view, &data);
        self.panel = Some(Panel {
            title: format!("the workspace — {}", self.workspace_view),
            lines,
        });
    }

    /// take_workspace_data keeps the names the mode line shows: the
    /// workspace this session works on, and the project the context
    /// stands on.
    fn take_workspace_data(&mut self, data: &Value) {
        self.workspace = Some(data.clone());
        let id = data
            .get("workspace")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string();
        if id.is_empty() {
            self.workspace_name = String::new();
        } else {
            let name = data
                .get("workspaces")
                .and_then(|held| held.as_array())
                .and_then(|held| {
                    held.iter().find(|one| {
                        one.get("id").and_then(|value| value.as_str()) == Some(id.as_str())
                    })
                })
                .and_then(|one| one.get("name").and_then(|value| value.as_str()))
                .unwrap_or(&id)
                .to_string();
            self.workspace_name = name;
        }
        self.project_name = data
            .get("project")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string();
    }

    /// take_editor reads the editor's own answer and fills the panel with
    /// it. The words are the editor's own: the multiplexer shows them and
    /// does not explain them.
    fn take_editor(&mut self, record: &Value) {
        let data = match record
            .get("outputs")
            .and_then(|outputs| outputs.get("editor"))
        {
            Some(data) => data.clone(),
            None => return,
        };
        let lines = crate::editor::lines(&data);
        self.panel = Some(Panel {
            title: "the editor — what it owns".to_string(),
            lines,
        });
    }

    /// take_git reads the layer's answer and fills the panel with it.
    fn take_git(&mut self, record: &Value) {
        let data = match record
            .get("outputs")
            .and_then(|outputs| outputs.get("git"))
        {
            Some(data) => data.clone(),
            None => return,
        };
        self.git = Some(data.clone());
        let lines = crate::git::lines(&self.git_want, &data);
        self.panel = Some(Panel {
            title: format!("the git — {}", self.git_want),
            lines,
        });
    }

    /// select_command runs one command of the selection: the point moves
    /// over the visible text of the focused pane, the mark is the
    /// anchor, and the region is the text between the mark and the
    /// point.
    fn select_command(&mut self, command: Command) -> Action {
        let lines = self.select_lines();
        match command {
            Command::SelectLeft => self.select.left(&lines),
            Command::SelectRight => self.select.right(&lines),
            Command::SelectUp => self.select.up(&lines),
            Command::SelectDown => self.select.down(&lines),
            Command::SelectWordLeft => self.select.word_left(&lines),
            Command::SelectWordRight => self.select.word_right(&lines),
            Command::SelectMark => {
                self.select.set_mark();
                self.message = "the mark is set where the point stands".to_string();
            }
            Command::SelectPopMark => {
                self.select.pop_mark();
                self.message = "the mark is popped; the anchor below it stands".to_string();
            }
            Command::SelectCopy => return self.copy_region(&lines),
            Command::SelectCopyLine => return self.copy_line(&lines),
            Command::SelectSend => return self.send_region(&lines),
            Command::SelectAgentHere => return self.agent_here(&lines),
            Command::PageUp | Command::PageDown => {
                // The view scrolled, so the text under the point is fresh
                // text: the pick starts again over it, and the mark that
                // named a line of the old window is gone with it.
                let up = command == Command::PageUp;
                if self.scroll_view(up) {
                    self.select.restart();
                    self.message = format!(
                        "the view scrolled; the pick starts again over the fresh text ({} back)",
                        self.scroll_distance()
                    );
                } else {
                    self.message =
                        "the view did not move, so the pick stands where it stands".to_string();
                }
            }
            Command::LeaveSelect => {
                self.mode = Mode::Visual;
                self.message =
                    "the selection is closed: nothing was copied and nothing was sent".to_string();
            }
            _ => {}
        }
        Action::Nothing
    }

    /// select_lines answers the visible lines of the focused pane: the
    /// lines the multiplexer draws, so a line that has scrolled out of
    /// the pane cannot be picked, because it cannot be seen.
    fn select_lines(&self) -> Vec<String> {
        let cols = self.cols.max(20);
        let (top, area_rows) = self.area();
        let rects = self.rects(cols, area_rows, top);
        let members = self.tab_panes();
        let at = match members.iter().position(|index| *index == self.focused) {
            Some(at) => at,
            None => return Vec::new(),
        };
        let rect = match rects.get(at) {
            Some(rect) => rect,
            None => return Vec::new(),
        };
        let height = rect.rows.saturating_sub(2) as usize;
        self.window(members[at], height)
    }

    /// copy_region puts the region into the multiplexer's own ring, and
    /// answers the line it copied.
    fn copy_region(&mut self, lines: &[String]) -> Action {
        let text = self.select.region(lines);
        if text.is_empty() {
            self.message = "there is no region: the mark is not set".to_string();
            return Action::Nothing;
        }
        self.ring.insert(0, text.clone());
        if self.ring.len() > RING_KEPT {
            self.ring.pop();
        }
        self.message = format!("the region is copied: {}", first_line(&text));
        Action::Nothing
    }

    /// copy_line puts the line the point stands on into the
    /// multiplexer's own ring.
    fn copy_line(&mut self, lines: &[String]) -> Action {
        let text = self.select.line_text(lines);
        if text.is_empty() {
            self.message = "the line is empty".to_string();
            return Action::Nothing;
        }
        self.ring.insert(0, text.clone());
        if self.ring.len() > RING_KEPT {
            self.ring.pop();
        }
        self.message = format!("the line is copied: {}", first_line(&text));
        Action::Nothing
    }

    /// send_region asks the holder to send the region to the agents. The
    /// bundle is built by the holder, where the redaction seam is, and the
    /// agents that are open are the ones that receive it. The pane the
    /// region came from is named, so the holder can add that pane's command
    /// record to the bundle.
    fn send_region(&mut self, lines: &[String]) -> Action {
        let text = self.select.region(lines);
        if text.is_empty() {
            self.message = "there is no region: the mark is not set".to_string();
            return Action::Nothing;
        }
        let program = self.agent_program.clone();
        let pane = self.focused_pane();
        self.message = "the region is on its way to the agents".to_string();
        Action::Request(json!({
            "op": "send-agent",
            "selection": text,
            "target": agent_name(&program),
            "from": pane,
            "why": "the owner sent the picked text to the agents",
        }))
    }

    /// agent_here asks the holder for an agent beside the focused pane,
    /// with the picked text in the bundle.
    fn agent_here(&mut self, lines: &[String]) -> Action {
        let program = self.agent_program.clone();
        let target = agent_name(&program);
        let pane = self.focused_pane();
        let text = self.select.region(lines);
        let why = format!("the owner opened the agent beside the pane {}", pane);
        self.message = format!("the agent is opening with the picked text of {}", pane);
        Action::Request(json!({
            "op": "open",
            "name": "agent",
            "program": program,
            "tab": self.focused_tab(),
            "context": {
                "pane": pane,
                "target": target,
                "why": why,
                "selection": text,
            }
        }))
    }

    /// open_agent asks the holder for an agent pane beside the focused one,
    /// with the context of that pane attached: the shell output, the shell,
    /// the place and the why. Nothing is copied by hand.
    ///
    /// The context is the tail of the pane's log: the holder sends every
    /// record to the clients that watch it, so the screen already holds
    /// what the log holds.
    fn open_agent(&mut self) -> Action {
        let program = self.agent_program.clone();
        let target = agent_name(&program);
        let pane = self.focused_pane();
        let why = format!("the owner asked for the agent beside the pane {}", pane);
        self.message = format!("the agent is opening with the context of {}", pane);
        // The context is the tail of that pane's log, and the log belongs to
        // the holder: the screen asks for the context and never copies it.
        Action::Request(json!({
            "op": "open",
            "name": "agent",
            "program": program,
            "tab": self.focused_tab(),
            "context": {
                "pane": pane,
                "target": target,
                "why": why,
            }
        }))
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
            ["pane", "grow"] => self.run(Command::PaneGrow),
            ["pane", "shrink"] => self.run(Command::PaneShrink),
            ["workspace"] => self.run(Command::WorkspaceList),
            ["workspace", "context"] => self.run(Command::WorkspaceContext),
            ["workspace", "open", name] => Action::Request(json!({
                "op": "workspace",
                "what": "open",
                "name": name
            })),
            ["workspace", "create", name] => Action::Request(json!({
                "op": "workspace",
                "what": "create",
                "name": name
            })),
            ["workspace", "project", name] => Action::Request(json!({
                "op": "workspace",
                "what": "project",
                "name": name
            })),
            ["agent"] => self.run(Command::OpenAgent),
            ["editor"] => self.run(Command::OpenEditor),
            ["records"] => self.run(Command::ShowRecords),
            ["sessions"] => self.run(Command::ShowSessions),
            ["scroll", "up"] => self.run(Command::PageUp),
            ["scroll", "down"] => self.run(Command::PageDown),
            ["copy", pane, first, last] => {
                // The lines of a pane, counted from one: the view shows the
                // count, so the owner and the agent name the same line.
                self.copy_lines(pane, first, last);
                Action::Nothing
            }
            ["paste", pane] => self.paste_into(pane),
            ["paste", "agent"] => self.paste_to_agent(),
            ["focus", pane] => {
                self.focus_pane(pane);
                Action::Nothing
            }
            ["view"] => Action::Nothing,
            other => {
                self.message = format!("{} is not a command", other.join(" "));
                Action::Nothing
            }
        }
    }

    /// control_words runs the words an agent sent, the way the owner runs
    /// them: the words are the words of the command line, and the command
    /// line is the owner's own path. It is public because the agent's door
    /// is this screen, and the agent must not get a second set of commands.
    pub fn control_words(&mut self, said: &str) -> Action {
        self.run_command(said)
    }

    /// wait_for_state says the agent's request waits for the state: the
    /// answer the agent gets is the state as it stands.
    pub fn wait_for_state(&mut self, id: String) {
        self.pending = Some(id);
        self.fresh = false;
    }

    /// take_pending answers the agent's request when the state has arrived,
    /// and nothing before: an answer that carries an old picture is a lie
    /// the agent would act on.
    pub fn take_pending(&mut self) -> Option<String> {
        if !self.fresh {
            return None;
        }
        self.fresh = false;
        self.pending.take()
    }

    /// view answers what the screen holds right now: the tabs, the panes
    /// with their text and their scroll, the focus, and the ring of copies.
    /// The agent cannot see the screen, so the screen says what is on it.
    pub fn view(&self) -> Value {
        let mut panes: Vec<Value> = Vec::new();
        for pane in &self.panes {
            let first = pane.lines.len().saturating_sub(VIEW_LINES);
            let mut text: Vec<String> = Vec::new();
            for (at, line) in pane.lines.iter().enumerate().skip(first) {
                text.push(format!("{}: {}", at + 1, line));
            }
            panes.push(json!({
                "name": pane.name.clone(),
                "tab": pane.tab.clone(),
                "scroll": pane.scroll,
                "lines": pane.lines.len(),
                "text": text
            }));
        }
        json!({
            "tabs": self.tabs.clone(),
            "tab": self.tab,
            "focused": self.focused_pane(),
            "panes": panes,
            "ring": self.ring.clone(),
            "message": self.message.clone()
        })
    }

    /// copy_lines copies the lines of a pane into the multiplexer's own ring,
    /// the ring the owner's own copy fills. The lines are the pane's own
    /// lines, counted from one, and the view shows that count, so the owner
    /// and the agent name the same line.
    fn copy_lines(&mut self, name: &str, first: &str, last: &str) -> bool {
        let first_at: usize = match first.parse() {
            Ok(value) => value,
            Err(_) => {
                self.message = format!("{} is not a line number", first);
                return false;
            }
        };
        let last_at: usize = match last.parse() {
            Ok(value) => value,
            Err(_) => {
                self.message = format!("{} is not a line number", last);
                return false;
            }
        };
        let copied = {
            let mut error = String::new();
            let text = match self.panes.iter().find(|pane| pane.name == name) {
                Some(pane) => {
                    if pane.lines.is_empty() {
                        error = format!("the pane {} has said nothing yet", name);
                        String::new()
                    } else if first_at > pane.lines.len() {
                        error = format!("the pane {} holds {} lines", name, pane.lines.len());
                        String::new()
                    } else {
                        let from = first_at.max(1);
                        let to = last_at.max(from).min(pane.lines.len());
                        pane.lines[from - 1..to].join("\n")
                    }
                }
                None => {
                    error = format!("there is no pane named {}", name);
                    String::new()
                }
            };
            (text, error)
        };
        if !copied.1.is_empty() {
            self.message = copied.1;
            return false;
        }
        let text = copied.0;
        if text.is_empty() {
            self.message = "there is nothing to copy".to_string();
            return false;
        }
        self.ring.insert(0, text.clone());
        if self.ring.len() > RING_KEPT {
            self.ring.pop();
        }
        self.message = format!(
            "the lines {} to {} of {} are copied: {}",
            first_at,
            last_at.max(first_at),
            name,
            first_line(&text)
        );
        true
    }

    /// paste_into puts the newest copy into a pane, the way the owner's own
    /// paste does: the text goes to the pane's own program.
    fn paste_into(&mut self, name: &str) -> Action {
        let text = match self.ring.first() {
            Some(found) => found.clone(),
            None => {
                self.message = "the ring is empty: nothing was copied".to_string();
                return Action::Nothing;
            }
        };
        if !self.panes.iter().any(|pane| pane.name == name) {
            self.message = format!("there is no pane named {}", name);
            return Action::Nothing;
        }
        self.message = format!("the copy is on its way to {}", name);
        Action::Request(json!({
            "op": "send",
            "pane": name,
            "data": text
        }))
    }

    /// paste_to_agent sends the newest copy to the agents, the way the
    /// owner's own send does: the bundle carries the text and the why.
    fn paste_to_agent(&mut self) -> Action {
        let text = match self.ring.first() {
            Some(found) => found.clone(),
            None => {
                self.message = "the ring is empty: nothing was copied".to_string();
                return Action::Nothing;
            }
        };
        let program = self.agent_program.clone();
        let target = agent_name(&program);
        let pane = self.focused_pane();
        self.message = "the copy is on its way to the agents".to_string();
        Action::Request(json!({
            "op": "send-agent",
            "selection": text,
            "target": target,
            "from": pane,
            "why": "the agent sent the copied text to the agents"
        }))
    }

    /// change_weight asks the holder for more of the space, or less of it,
    /// for the focused pane: the pane's share is its weight, and the layout
    /// file keeps it.
    fn change_weight(&mut self, by: i32) -> Action {
        let pane = self.focused_pane();
        if pane.is_empty() {
            self.message = "there is no pane to change".to_string();
            return Action::Nothing;
        }
        let weight = self
            .panes
            .iter()
            .find(|held| held.name == pane)
            .map(|held| held.weight)
            .unwrap_or(1) as i32;
        let next = (weight + by).max(1) as u16;
        if next as i32 == weight {
            self.message = "the pane already has the smallest share".to_string();
            return Action::Nothing;
        }
        self.message = format!("the pane {} takes {} of the space", pane, next);
        Action::Request(json!({
            "op": "weight",
            "pane": pane,
            "weight": next
        }))
    }

    /// focus_pane gives the focus to the pane with that name.
    fn focus_pane(&mut self, name: &str) -> bool {        match self.panes.iter().position(|pane| pane.name == name) {
            Some(at) => {
                self.focused = at;
                self.message = format!("the focus is on {}", name);
                true
            }
            None => {
                self.message = format!("there is no pane named {}", name);
                false
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
        if map == Context::Select {
            lines.push("  Escape leaves the selection and does nothing else".to_string());
        } else {
            lines.push("  Escape goes back one level".to_string());
        }
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

/// line_holds answers whether a record on the wire says a thing.
fn line_holds(line: &str, what: &str) -> bool {
    match serde_json::from_str::<Value>(line) {
        Ok(value) => value.get("what").and_then(|part| part.as_str()) == Some(what),
        Err(_) => false,
    }
}

/// agent_name answers the name of the agent program: the last piece of its
/// path. The target of a bundle is named, never inferred.
pub fn agent_name(program: &str) -> String {
    program
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or(program)
        .to_string()
}

/// clip answers the text with no more than width characters, and no more
/// than one line.
fn clip(text: &str, width: usize) -> String {
    // The escape sequences take no room on the screen, so they are not
    // counted, and they are never cut in half.
    let mut out = String::new();
    let mut count = 0;
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\x1b' {
            out.push(character);
            for next in characters.by_ref() {
                out.push(next);
                if next.is_ascii_alphabetic() {
                    break;
                }
            }
            continue;
        }
        if count >= width {
            break;
        }
        out.push(character);
        count += 1;
    }
    out
}

/// first_line answers the first line of a text, for a message that names
/// what was copied.
fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").to_string()
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
///
/// The config comes in with the screen: it is applied before the first draw,
/// and it is looked at again before every other draw, so a change to the file
/// is in force without a restart. The check is the loop's, not a watcher's:
/// the loop turns on an event, and that is when the file is read.
pub fn session(
    fd: libc::c_int,
    client_name: &str,
    agent_program: String,
    editor_program: String,
    editor_mcp: Vec<String>,
    mut config: ConfigFile,
) -> Result<(), String> {
    let saved = tty::save_termios(libc::STDIN_FILENO).ok();
    let _ = tty::make_raw(libc::STDIN_FILENO);
    let mut screen = Screen::empty(agent_program, editor_program, editor_mcp);
    screen.set_level(config.config().level);
    screen.set_tab_bar(config.config().tab_bar);
    // A config file that is there and was not used says so where the owner
    // reads it, and the screen runs on what the last good one said.
    if let Some(why) = config.problem() {
        screen.message = why.to_string();
    }
    wire::ask(fd, &json!({ "op": "state", "client": client_name }))?;
    wire::ask(
        fd,
        &json!({
            "op": "attach",
            "client": client_name,
            "role": "screen",
            "event-contract": crate::EVENT_CONTRACT,
            "holder-contract": crate::HOLDER_CONTRACT
        }),
    )?;

    let mut pending = String::new();
    let mut out = std::io::stdout();
    let mut leave = false;
    let mut detached = false;
    let mut keys_done = false;
    // A client that leaves must be heard: it detaches and waits for the
    // holder's answer, so a request it asked for is never lost to a
    // connection that closed too early.
    while !leave || !detached {
        // The window: the terminal's size is the session's size, and the
        // holder tells every pane — the shells and the editors alike.
        let size = tty::window_size(libc::STDOUT_FILENO).unwrap_or((80, 24));
        if size.0 != screen.cols || size.1 != screen.rows {
            screen.cols = size.0;
            screen.rows = size.1;
            // The rows the panes get: the window minus the screen's own
            // furniture. The holder gives every program the size of the
            // place it is drawn in, so the two cannot drift apart.
            let (_, area_rows) = screen.area();
            wire::ask(
                fd,
                &json!({
                    "op": "resize",
                    "client": client_name,
                    "cols": size.0,
                    "rows": size.1,
                    "area-rows": area_rows
                }),
            )?;
        }

        // The keys are only read once the screen knows the panes: a key that
        // arrives before the state would go to a pane the screen has not met.
        let ready = !screen.panes.is_empty() && !keys_done;
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
                // The agent's request is not a record of the session: it is
                // the agent's words, and the screen runs them the way the
                // owner's own keys run them.
                let asked: Value = match serde_json::from_str(&line) {
                    Ok(found) => found,
                    Err(_) => Value::Null,
                };
                if control::is_request(&asked) {
                    let (id, words) = control::request_of(&asked);
                    let outcome = control::run(&mut screen, &words);
                    if let Some(mut ask) = outcome.ask {
                        ask["client"] = Value::from(client_name);
                        wire::ask(fd, &ask)?;
                    }
                    // The state is asked for, so the answer the agent gets is
                    // the state as it stands and not the state as it was.
                    screen.wait_for_state(id);
                    wire::ask(fd, &json!({ "op": "state", "client": client_name }))?;
                    continue;
                }
                take_record(&mut screen, &line);
                if let Some(id) = screen.take_pending() {
                    let data = screen.view();
                    wire::ask(fd, &control::answer(&id, &data))?;
                }
                if line_holds(&line, "the client detached") {
                    detached = true;
                }
            }
        }

        // A pipe that is at its end says POLLHUP, not POLLIN: the end of the
        // keys is an event too, and the client must hear it.
        if fds.len() > 1 && fds[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let mut buffer = [0u8; 1024];
            let got = wire::read(libc::STDIN_FILENO, &mut buffer)?;
            if got == 0 {
                // The keys are over: the client detaches and waits to be
                // answered, and the wait ends on the answer.
                keys_done = true;
                if !leave {
                    leave = true;
                    wire::ask(fd, &json!({ "op": "detach", "client": client_name }))?;
                }
                continue;
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
                    Action::AskEditor => {
                        // The holder asks the editor, not the client: the
                        // client holds no child process, and the command
                        // that starts the editor's server is only a word
                        // here.
                        let command = screen.editor_mcp.clone();
                        wire::ask(
                            fd,
                            &json!({
                                "op": "editor",
                                "client": client_name,
                                "command": command,
                                "capability": "dashboard"
                            }),
                        )?;
                    }
                    Action::Quit => {
                        leave = true;
                        keys_done = true;
                        wire::ask(fd, &json!({ "op": "detach", "client": client_name }))?;
                    }
                }
            }
        }

        // The config is looked at once per turn of the loop, before the
        // drawing: a file that changed is in force at this draw, and a file
        // that does not parse leaves the values in force and says why in the
        // message line. No timer and no thread: the loop turns on an event.
        match config.reload_if_changed() {
            Reload::Unchanged => {}
            Reload::Changed(now) => {
                screen.set_level(now.level);
                screen.set_tab_bar(now.tab_bar);
                let from = config.path().display();
                screen.message = format!("the config was reloaded from {}", from);
            }
            Reload::Broken(why) => {
                screen.message = format!("the config is not used: {}", why);
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
    if what == "the workspace was read" {
        screen.take_workspace(&record);
    }
    if what == "the git state was read" {
        screen.take_git(&record);
        return;
    }
    if what == "the editor was asked" {
        screen.take_editor(&record);
        return;
    }
    if who == "holder" {
        screen.take_state(&record);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// a_screen is a screen on a window big enough to draw one pane, so the
    /// drawing can be read for what it holds.
    fn a_screen() -> Screen {
        let mut screen = Screen::empty("opencode".to_string(), "editor".to_string(), Vec::new());
        screen.cols = 60;
        screen.rows = 12;
        screen.tabs = vec!["main".to_string()];
        screen.panes = vec![PaneView {
            name: "work".to_string(),
            tab: "main".to_string(),
            weight: 1,
            lines: Vec::new(),
            scroll: 0,
        }];
        screen
    }

    #[test]
    fn the_config_sets_the_level_and_the_tab_bar() {
        let mut screen = a_screen();
        screen.set_level(0);
        screen.set_tab_bar(false);
        assert_eq!(screen.level(), 0);
        assert_eq!(screen.tab_bar_on(), false);
        let drawing = screen.draw();
        assert!(drawing.contains("VISUAL") == false, "no mode row: {:?}", drawing);
        assert!(drawing.contains("[main]") == false, "no tab bar: {:?}", drawing);
    }

    #[test]
    fn a_level_above_three_is_taken_as_three() {
        let mut screen = a_screen();
        screen.set_level(9);
        assert_eq!(screen.level(), 3);
    }

    #[test]
    fn the_tab_bar_can_be_off_while_the_mode_row_stays() {
        let mut screen = a_screen();
        screen.set_level(2);
        screen.set_tab_bar(false);
        let drawing = screen.draw();
        assert!(drawing.contains("VISUAL"), "the mode row stays: {:?}", drawing);
        assert!(drawing.contains("[main]") == false, "the tab bar is gone: {:?}", drawing);
    }

    /// a_screen_with_words is a screen whose focused pane said forty
    /// numbered lines, so a page is a page and there is something to
    /// scroll to.
    fn a_screen_with_words() -> Screen {
        let mut screen = a_screen();
        screen.panes[0].lines = (1..=40).map(|at| format!("line {}", at)).collect();
        screen
    }

    #[test]
    fn the_page_key_scrolls_the_view_to_the_older_words() {
        let mut screen = a_screen_with_words();
        let before = screen.window(0, 6);
        assert_eq!(before.first(), Some(&"line 35".to_string()));
        assert!(screen.scroll_view(true), "the view moved");
        let after = screen.window(0, 6);
        assert_eq!(after.first(), Some(&"line 29".to_string()));
        assert_eq!(after.last(), Some(&"line 34".to_string()));
    }

    #[test]
    fn the_view_stops_at_the_oldest_page() {
        let mut screen = a_screen_with_words();
        let mut moved = true;
        let mut pages = 0;
        while moved {
            moved = screen.scroll_view(true);
            if moved {
                pages = pages + 1;
            }
        }
        assert!(pages > 0, "the view moved at least once");
        assert_eq!(screen.scroll_distance(), 34);
        let oldest = screen.window(0, 6);
        assert_eq!(oldest.first(), Some(&"line 1".to_string()));
    }

    #[test]
    fn the_pick_restarts_over_the_fresh_text() {
        let mut screen = a_screen_with_words();
        screen.mode = Mode::Select;
        screen.select.right(&screen.select_lines());
        screen.select.set_mark();
        assert!(screen.select.mark().is_some(), "the mark stands");
        assert!(screen.scroll_view(true), "the view moved");
        screen.select.restart();
        assert_eq!(screen.select.point, (0, 0));
        assert!(screen.select.mark().is_none(), "the mark is gone");
    }
}
