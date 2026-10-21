// One job: the keymap — the keys that mean what, as data.
//
// The commands and the keymap explorer read this one table. What the keys do
// and what the explorer shows are the same facts, so they cannot drift apart
// (rule 03: one file, one job; rule 07: the program never learns which key
// asked).
//
// There is no modifier in here: no Control, no Alt, no Meta, and no prefix
// chord. The keys are the ordinary keys of the keyboard, and the sequences
// are ordinary keys one after another. A Control key that the owner presses
// belongs to the program in the pane, not to the multiplexer.

/// Mode is whose keys these are.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// Visual is the multiplexer's own: the keys are commands.
    Visual,
    /// Insert is the pane's own: the keys are text.
    Insert,
    /// Command is the command line: the keys are words.
    Command,
    /// Explorer is the keymap explorer: the keys walk the keymap.
    Explorer,
    /// Select is the selection overlay: the keys pick the visible text.
    Select,
}

/// Context is which map the keys are read against.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Context {
    Root,
    Tabs,
    Panes,
    Commands,
    Sessions,
    Git,
    Select,
}

impl Context {
    /// title is what the explorer calls this map.
    pub fn title(&self) -> &'static str {
        match self {
            Context::Root => "the root map",
            Context::Tabs => "the tabs",
            Context::Panes => "the panes",
            Context::Commands => "the commands",
            Context::Sessions => "the sessions",
            Context::Git => "the git",
            Context::Select => "the selection",
        }
    }

    /// prefix is the key that opens this map, and the first key of every
    /// sequence in it.
    pub fn prefix(&self) -> &'static [u8] {
        match self {
            Context::Root => b"",
            Context::Tabs => b"t",
            Context::Panes => b"p",
            Context::Commands => b"c",
            Context::Sessions => b"s",
            Context::Git => b"g",
            Context::Select => b"",
        }
    }
}

/// Command is what the multiplexer does. The dispatch does not know which key
/// asked for it, so a command can be run from a key, from the explorer, or
/// from the command line, and it does the same thing each time.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Command {
    Nothing,
    /// EnterInsert puts the keyboard into the focused pane.
    EnterInsert,
    /// OpenCommandLine opens the line where the owner writes a command.
    OpenCommandLine,
    /// OpenExplorer opens the keymap explorer.
    OpenExplorer,
    /// CloseExplorer closes the keymap explorer and gives the keyboard back.
    CloseExplorer,
    /// Detach leaves the multiplexer; the session goes on without it.
    Detach,
    TabAdd,
    TabClose,
    TabRename,
    TabNext,
    TabPrevious,
    PaneAdd,
    PaneClose,
    PaneRename,
    PaneNext,
    PanePrevious,
    /// OpenAgent opens the agent beside the focused pane, with the pane's
    /// context attached.
    OpenAgent,
    /// OpenEditor opens the editor beside the focused pane.
    OpenEditor,
    /// ShowRecords opens the panel with the session's records.
    ShowRecords,
    /// ShowSessions opens the panel with the sessions.
    ShowSessions,
    /// GitOverview shows the repository, its worktrees and its distance.
    GitOverview,
    /// GitChanged shows the changed files.
    GitChanged,
    /// GitDiff shows the diff of the working tree against the index.
    GitDiff,
    /// GitHistory shows the commits.
    GitHistory,
    /// GitBranches shows the branches and their distance.
    GitBranches,
    /// GitWorktrees shows every worktree of the repository.
    GitWorktrees,
    /// EnterSelect opens the selection on the focused pane.
    EnterSelect,
    /// SelectLeft moves the point one character to the left.
    SelectLeft,
    /// SelectRight moves the point one character to the right.
    SelectRight,
    /// SelectUp moves the point one line up.
    SelectUp,
    /// SelectDown moves the point one line down.
    SelectDown,
    /// SelectWordLeft moves the point to the start of the word before it.
    SelectWordLeft,
    /// SelectWordRight moves the point to the start of the next word.
    SelectWordRight,
    /// SelectMark pushes the mark where the point stands.
    SelectMark,
    /// SelectPopMark takes the newest mark off the ring.
    SelectPopMark,
    /// SelectCopy copies the region into the multiplexer's own ring.
    SelectCopy,
    /// SelectCopyLine copies the line the point stands on.
    SelectCopyLine,
    /// SelectSend sends the region to the agent in the bundle.
    SelectSend,
    /// SelectAgentHere opens the agent beside the pane, with the region.
    SelectAgentHere,
    /// LeaveSelect leaves the selection and does nothing else.
    LeaveSelect,
}

/// Action is what a binding does: run a command, or open a sub-map.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action {
    Command(Command),
    Map(Context),
}

/// Need is the condition under which a binding can run now.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Need {
    Always,
    /// AnotherTab means the binding needs a second tab to move to.
    AnotherTab,
    /// AnotherPane means the binding needs a second pane to move to.
    AnotherPane,
}

/// State is what the multiplexer holds right now, so a binding can say
/// whether it can run.
#[derive(Clone, Copy, Debug)]
pub struct State {
    pub tabs: usize,
    pub panes: usize,
}

/// Binding is one key (or one sequence) and what it means.
pub struct Binding {
    /// keys is what the explorer shows: the key, or the sequence.
    pub keys: &'static str,
    /// bytes is what the keyboard sends for it, the whole sequence.
    pub bytes: &'static [u8],
    /// about is one line about what it does.
    pub about: &'static str,
    /// action is what it does: a command, or a sub-map.
    pub action: Action,
    /// need is what it needs to be able to run now.
    pub need: Need,
}

impl Binding {
    /// available answers whether this binding can run in this state, so the
    /// explorer can say "not now" instead of pretending.
    pub fn available(&self, state: &State) -> bool {
        match self.need {
            Need::Always => true,
            Need::AnotherTab => state.tabs > 1,
            Need::AnotherPane => state.panes > 1,
        }
    }

    /// is_map answers whether this binding opens a sub-map instead of running
    /// a command.
    pub fn is_map(&self) -> bool {
        matches!(self.action, Action::Map(_))
    }

    /// action_as_command answers the command this binding runs, when it runs
    /// one.
    pub fn action_as_command(&self) -> Option<Command> {
        match self.action {
            Action::Command(command) => Some(command),
            Action::Map(_) => None,
        }
    }
}

/// ROOT is the map of Visual mode: what the ordinary keys do.
pub static ROOT: &[Binding] = &[
    Binding {
        keys: "i",
        bytes: b"i",
        about: "type into the focused pane",
        action: Action::Command(Command::EnterInsert),
        need: Need::Always,
    },
    Binding {
        keys: "Space",
        bytes: b" ",
        about: "the keymap explorer: every key, and what it means",
        action: Action::Command(Command::OpenExplorer),
        need: Need::Always,
    },
    Binding {
        keys: "?",
        bytes: b"?",
        about: "the keymap explorer (the same as Space)",
        action: Action::Command(Command::OpenExplorer),
        need: Need::Always,
    },
    Binding {
        keys: ":",
        bytes: b":",
        about: "the command line",
        action: Action::Command(Command::OpenCommandLine),
        need: Need::Always,
    },
    Binding {
        keys: "q",
        bytes: b"q",
        about: "leave the multiplexer; the session goes on without it",
        action: Action::Command(Command::Detach),
        need: Need::Always,
    },
    Binding {
        keys: "Left",
        bytes: b"\x1b[D",
        about: "the focus to the pane before",
        action: Action::Command(Command::PanePrevious),
        need: Need::AnotherPane,
    },
    Binding {
        keys: "Right",
        bytes: b"\x1b[C",
        about: "the focus to the next pane",
        action: Action::Command(Command::PaneNext),
        need: Need::AnotherPane,
    },
    Binding {
        keys: "Up",
        bytes: b"\x1b[A",
        about: "the focus to the pane before",
        action: Action::Command(Command::PanePrevious),
        need: Need::AnotherPane,
    },
    Binding {
        keys: "Down",
        bytes: b"\x1b[B",
        about: "the focus to the next pane",
        action: Action::Command(Command::PaneNext),
        need: Need::AnotherPane,
    },
    Binding {
        keys: "t",
        bytes: b"t",
        about: "the tabs",
        action: Action::Map(Context::Tabs),
        need: Need::Always,
    },
    Binding {
        keys: "p",
        bytes: b"p",
        about: "the panes",
        action: Action::Map(Context::Panes),
        need: Need::Always,
    },
    Binding {
        keys: "c",
        bytes: b"c",
        about: "the commands",
        action: Action::Map(Context::Commands),
        need: Need::Always,
    },
    Binding {
        keys: "s",
        bytes: b"s",
        about: "the sessions",
        action: Action::Map(Context::Sessions),
        need: Need::Always,
    },
    Binding {
        keys: "g",
        bytes: b"g",
        about: "the git: the repository, the worktrees, the changes",
        action: Action::Map(Context::Git),
        need: Need::Always,
    },
    Binding {
        keys: "v",
        bytes: b"v",
        about: "the selection: pick the text on the screen",
        action: Action::Map(Context::Select),
        need: Need::Always,
    },
];

/// SELECT is the map of the selection. The keys move a point over the
/// visible text of the focused pane, one key sets the mark, and the
/// region is the text between the mark and the point.
///
/// The escape leaves the selection and does nothing else: no text is
/// copied, no bundle is sent and no pane opens. The escape is not a
/// binding here: the byte stream is what tells a lone escape from the
/// escape that begins an arrow key, and the program reads the escape
/// where the byte stream hands it over.
pub static SELECT: &[Binding] = &[
    Binding {
        keys: "Left",
        bytes: b"\x1b[D",
        about: "the point one character to the left",
        action: Action::Command(Command::SelectLeft),
        need: Need::Always,
    },
    Binding {
        keys: "Right",
        bytes: b"\x1b[C",
        about: "the point one character to the right",
        action: Action::Command(Command::SelectRight),
        need: Need::Always,
    },
    Binding {
        keys: "Up",
        bytes: b"\x1b[A",
        about: "the point one line up",
        action: Action::Command(Command::SelectUp),
        need: Need::Always,
    },
    Binding {
        keys: "Down",
        bytes: b"\x1b[B",
        about: "the point one line down",
        action: Action::Command(Command::SelectDown),
        need: Need::Always,
    },
    Binding {
        keys: "w b",
        bytes: b"wb",
        about: "the point to the start of the word before it",
        action: Action::Command(Command::SelectWordLeft),
        need: Need::Always,
    },
    Binding {
        keys: "w f",
        bytes: b"wf",
        about: "the point to the start of the next word",
        action: Action::Command(Command::SelectWordRight),
        need: Need::Always,
    },
    Binding {
        keys: "m",
        bytes: b"m",
        about: "the mark: the anchor of the region",
        action: Action::Command(Command::SelectMark),
        need: Need::Always,
    },
    Binding {
        keys: "M",
        bytes: b"M",
        about: "pop the newest mark; the anchor below it stands",
        action: Action::Command(Command::SelectPopMark),
        need: Need::Always,
    },
    Binding {
        keys: "y",
        bytes: b"y",
        about: "copy the region into the multiplexer's own ring",
        action: Action::Command(Command::SelectCopy),
        need: Need::Always,
    },
    Binding {
        keys: "Y",
        bytes: b"Y",
        about: "copy the line the point stands on",
        action: Action::Command(Command::SelectCopyLine),
        need: Need::Always,
    },
    Binding {
        keys: "s",
        bytes: b"s",
        about: "send the region to the agent, in the bundle",
        action: Action::Command(Command::SelectSend),
        need: Need::Always,
    },
    Binding {
        keys: "p o",
        bytes: b"po",
        about: "open the agent beside this pane, with the region",
        action: Action::Command(Command::SelectAgentHere),
        need: Need::Always,
    },
];

/// GIT is the map of the git commands. Every sequence starts with the key
/// that opens the map. Every one of them reads: the layer behind them
/// cannot change a repository.
pub static GIT: &[Binding] = &[
    Binding {
        keys: "g o",
        bytes: b"go",
        about: "the repository: the branch, the distance, the worktrees",
        action: Action::Command(Command::GitOverview),
        need: Need::Always,
    },
    Binding {
        keys: "g c",
        bytes: b"gc",
        about: "the changed files: staged, unstaged, untracked, conflicts",
        action: Action::Command(Command::GitChanged),
        need: Need::Always,
    },
    Binding {
        keys: "g d",
        bytes: b"gd",
        about: "the diff: the working tree against the index",
        action: Action::Command(Command::GitDiff),
        need: Need::Always,
    },
    Binding {
        keys: "g h",
        bytes: b"gh",
        about: "the history: the commits, newest first",
        action: Action::Command(Command::GitHistory),
        need: Need::Always,
    },
    Binding {
        keys: "g b",
        bytes: b"gb",
        about: "the branches, and how far they are from their upstream",
        action: Action::Command(Command::GitBranches),
        need: Need::Always,
    },
    Binding {
        keys: "g w",
        bytes: b"gw",
        about: "the worktrees: every one of them, and the changes it holds",
        action: Action::Command(Command::GitWorktrees),
        need: Need::Always,
    },
];

/// TABS is the map of the tab commands. Every sequence starts with the key
/// that opens the map.
pub static TABS: &[Binding] = &[
    Binding {
        keys: "t a",
        bytes: b"ta",
        about: "a new tab, with a pane in it",
        action: Action::Command(Command::TabAdd),
        need: Need::Always,
    },
    Binding {
        keys: "t c",
        bytes: b"tc",
        about: "close this tab",
        action: Action::Command(Command::TabClose),
        need: Need::Always,
    },
    Binding {
        keys: "t r",
        bytes: b"tr",
        about: "rename this tab",
        action: Action::Command(Command::TabRename),
        need: Need::Always,
    },
    Binding {
        keys: "t n",
        bytes: b"tn",
        about: "the next tab",
        action: Action::Command(Command::TabNext),
        need: Need::AnotherTab,
    },
    Binding {
        keys: "t p",
        bytes: b"tp",
        about: "the tab before",
        action: Action::Command(Command::TabPrevious),
        need: Need::AnotherTab,
    },
];

/// PANES is the map of the pane commands.
pub static PANES: &[Binding] = &[
    Binding {
        keys: "p a",
        bytes: b"pa",
        about: "a new pane",
        action: Action::Command(Command::PaneAdd),
        need: Need::Always,
    },
    Binding {
        keys: "p c",
        bytes: b"pc",
        about: "close this pane",
        action: Action::Command(Command::PaneClose),
        need: Need::Always,
    },
    Binding {
        keys: "p r",
        bytes: b"pr",
        about: "rename this pane",
        action: Action::Command(Command::PaneRename),
        need: Need::Always,
    },
    Binding {
        keys: "p n",
        bytes: b"pn",
        about: "the next pane",
        action: Action::Command(Command::PaneNext),
        need: Need::AnotherPane,
    },
    Binding {
        keys: "p p",
        bytes: b"pp",
        about: "the pane before",
        action: Action::Command(Command::PanePrevious),
        need: Need::AnotherPane,
    },
    Binding {
        keys: "p o",
        bytes: b"po",
        about: "open the agent beside this pane, with its context",
        action: Action::Command(Command::OpenAgent),
        need: Need::Always,
    },
    Binding {
        keys: "p e",
        bytes: b"pe",
        about: "open the editor beside this pane",
        action: Action::Command(Command::OpenEditor),
        need: Need::Always,
    },
];

/// COMMANDS is the map of the command commands.
pub static COMMANDS: &[Binding] = &[
    Binding {
        keys: "c l",
        bytes: b"cl",
        about: "the records of this session",
        action: Action::Command(Command::ShowRecords),
        need: Need::Always,
    },
    Binding {
        keys: "c :",
        bytes: b"c:",
        about: "the command line",
        action: Action::Command(Command::OpenCommandLine),
        need: Need::Always,
    },
];

/// SESSIONS is the map of the session commands.
pub static SESSIONS: &[Binding] = &[
    Binding {
        keys: "s d",
        bytes: b"sd",
        about: "detach: leave the multiplexer, the session goes on",
        action: Action::Command(Command::Detach),
        need: Need::Always,
    },
    Binding {
        keys: "s l",
        bytes: b"sl",
        about: "the sessions this multiplexer knows",
        action: Action::Command(Command::ShowSessions),
        need: Need::Always,
    },
];

/// bindings answers the bindings of one map. It is the only place that says
/// which map holds which bindings.
pub fn bindings(context: Context) -> &'static [Binding] {
    match context {
        Context::Root => ROOT,
        Context::Tabs => TABS,
        Context::Panes => PANES,
        Context::Commands => COMMANDS,
        Context::Sessions => SESSIONS,
        Context::Git => GIT,
        Context::Select => SELECT,
    }
}

/// Resolution is what one key means.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Resolution {
    /// Command means: run this command.
    Command(Command),
    /// Map means: open this sub-map.
    Map(Context),
    /// Pending means: the key is part of a sequence; wait for the next.
    Pending,
    /// Pass means: the key belongs to the program in the pane.
    Pass,
    /// Ignore means: the key means nothing here.
    Ignore,
}

/// Hit is what one key matched in one map.
enum Hit {
    Exact(Action),
    Partial(Action),
    None,
}

/// Keymap reads the keys and says what they mean. It holds the sequence that
/// is being typed and the map the explorer is showing, and nothing else: the
/// commands themselves do not live here.
pub struct Keymap {
    pending: Vec<u8>,
    group: Option<Context>,
    explorer: Context,
}

impl Keymap {
    /// empty is a keymap with nothing typed and the root map open.
    pub fn empty() -> Keymap {
        Keymap {
            pending: Vec::new(),
            group: None,
            explorer: Context::Root,
        }
    }

    /// pending_keys answers the keys of the sequence being typed, in the words
    /// the explorer shows them.
    pub fn pending_keys(&self) -> String {
        if self.pending.is_empty() {
            return String::new();
        }
        let mut text = String::new();
        for byte in &self.pending {
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(&key_name(*byte));
        }
        text
    }

    /// group answers the map a sequence opened, if any.
    pub fn group(&self) -> Option<Context> {
        self.group
    }

    /// explorer_map answers the map the explorer is showing.
    pub fn explorer_map(&self) -> Context {
        self.explorer
    }

    /// open_map puts the explorer on another map.
    pub fn open_map(&mut self, context: Context) {
        self.explorer = context;
        self.pending.clear();
    }

    /// cancel drops the sequence being typed and the group it opened.
    pub fn cancel(&mut self) {
        self.pending.clear();
        self.group = None;
    }

    /// resolve reads one key and says what it means, in the given mode.
    ///
    /// In INSERT the keys belong to the program in the pane, and only the
    /// Escape is the multiplexer's: it leaves Insert without being sent on.
    /// In VISUAL the keys are the multiplexer's, read against the root map
    /// (or the group a sequence opened). In the EXPLORER the keys are read
    /// against the map the explorer is showing.
    pub fn resolve(&mut self, mode: Mode, key: u8) -> Resolution {
        match mode {
            Mode::Insert => Resolution::Pass,
            Mode::Command => Resolution::Pass,
            Mode::Visual => self.resolve_visual(key),
            Mode::Explorer => self.resolve_explorer(key),
            Mode::Select => self.resolve_select(key),
        }
    }

    /// resolve_select reads one key in the SELECTION against the select
    /// map. The escape leaves the selection, and it is the one key that
    /// is read here and not through the table.
    fn resolve_select(&mut self, key: u8) -> Resolution {
        // The escape is read like every other key: the arrow keys begin
        // with an escape byte, and the sequence is only a sequence when
        // its bytes are all there. The map itself holds the escape, so
        // the leave is one fact and not a rule in the program.
        let mut candidate = self.pending.clone();
        candidate.push(key);
        match self.hit(Context::Select, &candidate) {
            Hit::Exact(Action::Command(command)) => {
                self.cancel();
                Resolution::Command(command)
            }
            Hit::Partial(_) => {
                self.pending = candidate;
                Resolution::Pending
            }
            Hit::None => {
                self.cancel();
                Resolution::Ignore
            }
            Hit::Exact(Action::Map(_)) => {
                self.cancel();
                Resolution::Ignore
            }
        }
    }

    /// resolve_visual reads a key in VISUAL mode against the root map and the
    /// group a sequence opened.
    fn resolve_visual(&mut self, key: u8) -> Resolution {
        let map = self.group.unwrap_or(Context::Root);
        let mut candidate = self.pending.clone();
        candidate.push(key);
        match self.hit(map, &candidate) {
            Hit::Exact(Action::Command(command)) => {
                self.cancel();
                Resolution::Command(command)
            }
            Hit::Exact(Action::Map(context)) => {
                if context == Context::Select {
                    // The selection is a mode and not a group: the mode
                    // line says which mode stands, and the keys of the
                    // selection are read against the select map.
                    self.cancel();
                    return Resolution::Command(Command::EnterSelect);
                }
                // The group is open: the next key is read against it.
                self.group = Some(context);
                self.pending = candidate;
                Resolution::Pending
            }
            Hit::Partial(Action::Map(context)) => {
                self.group = Some(context);
                self.pending = candidate;
                Resolution::Pending
            }
            Hit::Partial(Action::Command(_)) => {
                self.pending = candidate;
                Resolution::Pending
            }
            Hit::None => {
                if self.pending.is_empty() {
                    return Resolution::Ignore;
                }
                // The sequence was wrong: drop it and try the key on its own,
                // so one wrong key never runs a command by accident.
                self.cancel();
                self.resolve_visual(key)
            }
        }
    }

    /// resolve_explorer reads a key in the EXPLORER against the map the
    /// explorer is showing.
    fn resolve_explorer(&mut self, key: u8) -> Resolution {
        if key == 0x1b {
            // Escape cancels the exploration: one level up, or out of it.
            if self.explorer != Context::Root {
                self.explorer = Context::Root;
                self.pending.clear();
                return Resolution::Map(Context::Root);
            }
            return Resolution::Command(Command::CloseExplorer);
        }
        let prefix = self.explorer.prefix();
        let mut candidate = prefix.to_vec();
        candidate.extend_from_slice(&self.pending);
        candidate.push(key);
        match self.hit(self.explorer, &candidate) {
            Hit::Exact(Action::Command(command)) => {
                self.pending.clear();
                Resolution::Command(command)
            }
            Hit::Exact(Action::Map(context)) => {
                self.pending.clear();
                Resolution::Map(context)
            }
            Hit::Partial(_) => {
                self.pending = candidate[prefix.len()..].to_vec();
                Resolution::Pending
            }
            Hit::None => {
                self.pending.clear();
                Resolution::Ignore
            }
        }
    }

    /// hit answers what a candidate matches in one map: exactly, as the start
    /// of a longer sequence, or not at all.
    fn hit(&self, map: Context, candidate: &[u8]) -> Hit {
        for binding in bindings(map) {
            if binding.bytes == candidate {
                return Hit::Exact(binding.action);
            }
        }
        for binding in bindings(map) {
            if binding.bytes.len() > candidate.len() && binding.bytes.starts_with(candidate) {
                return Hit::Partial(binding.action);
            }
        }
        Hit::None
    }
}

/// key_name answers the name of one byte, the way the explorer shows it.
pub fn key_name(byte: u8) -> String {
    match byte {
        0x1b => "Escape".to_string(),
        0x0d => "Enter".to_string(),
        0x7f => "Backspace".to_string(),
        0x20 => "Space".to_string(),
        byte if byte.is_ascii_graphic() => (byte as char).to_string(),
        byte => format!("Ctrl-{}", (byte + 0x60) as char),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// state is a session with two tabs and two panes.
    fn state() -> State {
        State {
            tabs: 2,
            panes: 2,
        }
    }

    #[test]
    fn visual_starts_at_the_root_map() {
        let mut keymap = Keymap::empty();
        assert_eq!(keymap.explorer_map(), Context::Root);
        assert_eq!(keymap.group(), None);
    }

    #[test]
    fn the_i_enters_insert() {
        let mut keymap = Keymap::empty();
        assert_eq!(
            keymap.resolve(Mode::Visual, b'i'),
            Resolution::Command(Command::EnterInsert)
        );
    }

    #[test]
    fn space_opens_the_explorer_in_visual_mode() {
        let mut keymap = Keymap::empty();
        assert_eq!(
            keymap.resolve(Mode::Visual, b' '),
            Resolution::Command(Command::OpenExplorer)
        );
    }

    #[test]
    fn insert_mode_passes_the_keys_to_the_pane() {
        let mut keymap = Keymap::empty();
        assert_eq!(keymap.resolve(Mode::Insert, b'a'), Resolution::Pass);
        assert_eq!(keymap.resolve(Mode::Insert, b' '), Resolution::Pass);
        assert_eq!(keymap.resolve(Mode::Insert, 0x03), Resolution::Pass);
    }

    #[test]
    fn a_sequence_runs_the_command_of_its_last_key() {
        let mut keymap = Keymap::empty();
        assert_eq!(keymap.resolve(Mode::Visual, b'p'), Resolution::Pending);
        assert_eq!(keymap.group(), Some(Context::Panes));
        assert_eq!(
            keymap.resolve(Mode::Visual, b'a'),
            Resolution::Command(Command::PaneAdd)
        );
    }

    #[test]
    fn a_wrong_key_cancels_the_sequence_and_does_nothing() {
        let mut keymap = Keymap::empty();
        keymap.resolve(Mode::Visual, b'p');
        assert_eq!(keymap.resolve(Mode::Visual, b'z'), Resolution::Ignore);
        assert_eq!(keymap.pending_keys(), "");
        assert_eq!(keymap.group(), None);
    }

    #[test]
    fn the_escape_cancels_the_sequence() {
        let mut keymap = Keymap::empty();
        keymap.resolve(Mode::Visual, b'p');
        keymap.cancel();
        assert_eq!(keymap.pending_keys(), "");
        assert_eq!(keymap.resolve(Mode::Visual, b'a'), Resolution::Ignore);
    }

    #[test]
    fn the_explorer_shows_the_root_map_and_its_groups() {
        let mut keymap = Keymap::empty();
        assert_eq!(keymap.explorer_map(), Context::Root);
        assert_eq!(keymap.resolve(Mode::Explorer, b't'), Resolution::Map(Context::Tabs));
    }

    #[test]
    fn the_explorer_walks_into_a_group() {
        let mut keymap = Keymap::empty();
        assert_eq!(keymap.resolve(Mode::Explorer, b'p'), Resolution::Map(Context::Panes));
        keymap.open_map(Context::Panes);
        assert_eq!(keymap.explorer_map(), Context::Panes);
        assert_eq!(
            keymap.resolve(Mode::Explorer, b'o'),
            Resolution::Command(Command::OpenAgent)
        );
    }

    #[test]
    fn the_escape_leaves_the_explorer_one_level_up() {
        let mut keymap = Keymap::empty();
        keymap.open_map(Context::Panes);
        assert_eq!(keymap.resolve(Mode::Explorer, 0x1b), Resolution::Map(Context::Root));
        assert_eq!(keymap.explorer_map(), Context::Root);
        assert_eq!(
            keymap.resolve(Mode::Explorer, 0x1b),
            Resolution::Command(Command::CloseExplorer)
        );
    }

    #[test]
    fn no_binding_needs_a_modifier() {
        for context in [
            Context::Root,
            Context::Tabs,
            Context::Panes,
            Context::Commands,
            Context::Sessions,
        ] {
            for binding in bindings(context) {
                for byte in binding.bytes {
                    assert!(
                        *byte >= 0x20 || *byte == 0x1b,
                        "the binding {} holds a control key",
                        binding.keys
                    );
                }
            }
        }
    }

    #[test]
    fn every_binding_of_the_selection_is_reachable() {
        for binding in bindings(Context::Select) {
            let mut keymap = Keymap::empty();
            let last = *binding.bytes.last().unwrap();
            for byte in &binding.bytes[..binding.bytes.len() - 1] {
                keymap.resolve(Mode::Select, *byte);
            }
            let resolution = keymap.resolve(Mode::Select, last);
            assert_eq!(
                resolution,
                Resolution::Command(binding.action_as_command().unwrap()),
                "the binding {} does not run its command",
                binding.keys
            );
        }
    }

    #[test]
    fn every_binding_is_reachable_from_its_own_map() {
        for context in [
            Context::Root,
            Context::Tabs,
            Context::Panes,
            Context::Commands,
            Context::Sessions,
        ] {
            for binding in bindings(context) {
                let mut keymap = Keymap::empty();
                let last = *binding.bytes.last().unwrap();
                for byte in &binding.bytes[..binding.bytes.len() - 1] {
                    keymap.resolve(Mode::Visual, *byte);
                }
                let resolution = keymap.resolve(Mode::Visual, last);
                match binding.action_as_command() {
                    // A command binding runs the command it says.
                    Some(command) => assert_eq!(
                        resolution,
                        Resolution::Command(command),
                        "the binding {} does not run its command",
                        binding.keys
                    ),
                    // The selection is a mode and not a group: the key
                    // enters it, and the mode line says which mode stands.
                    None if binding.action == Action::Map(Context::Select) => {
                        assert_eq!(
                            resolution,
                            Resolution::Command(Command::EnterSelect),
                            "the binding {} does not enter the selection",
                            binding.keys
                        )
                    }
                    // A group binding opens the group and waits for the next
                    // key of that group.
                    None => assert_eq!(
                        resolution,
                        Resolution::Pending,
                        "the binding {} does not open its group",
                        binding.keys
                    ),
                }
            }
        }
    }

    #[test]
    fn a_binding_that_needs_another_tab_says_so() {
        let binding = TABS
            .iter()
            .find(|binding| binding.need == Need::AnotherTab)
            .expect("the tabs map has a binding that needs a second tab");
        let one = State {
            tabs: 1,
            panes: 1,
        };
        assert!(!binding.available(&one));
        assert!(binding.available(&state()));
    }

    #[test]
    fn the_explorer_shows_the_same_bindings_the_keys_use() {
        // The explorer and the keys read one table: the explorer shows the
        // root map, and the root map is what Visual mode reads.
        let mut keymap = Keymap::empty();
        for binding in ROOT {
            if binding.is_map() {
                continue;
            }
            let last = *binding.bytes.last().unwrap();
            let mut keys = Keymap::empty();
            for byte in &binding.bytes[..binding.bytes.len() - 1] {
                keys.resolve(Mode::Visual, *byte);
            }
            assert_eq!(
                keys.resolve(Mode::Visual, last),
                Resolution::Command(binding.action_as_command().unwrap()),
                "the binding {} does not do what the explorer shows",
                binding.keys
            );
        }
        let _ = keymap.explorer_map();
    }
}
