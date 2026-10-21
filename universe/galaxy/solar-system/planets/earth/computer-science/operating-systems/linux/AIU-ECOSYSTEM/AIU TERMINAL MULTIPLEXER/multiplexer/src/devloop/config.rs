// One job: the config — the values the client honors, where the file is read
// from, and whether it changed since the screen last looked.
//
// The file is JSON and the keys are the wire's: one object, kebab-case names.
// The two values the client honors today are the level (how much of the
// screen's own furniture is drawn, 0 to 3) and the tab bar (whether it is
// drawn at all):
//
//   { "level": 2, "tab-bar": true }
//
// Where the file comes from, in order: the file named by
// AIU_MULTIPLEXER_CONFIG, then $XDG_CONFIG_HOME/aiu-multiplexer/config.json,
// then $HOME/.config/aiu-multiplexer/config.json, then the baked defaults in
// the state directory, then the built-in defaults.
//
// resolve is the ONE place this area reads the environment — the same rule
// the machine area keeps for the Racket side, kept here for the Rust floor
// so no other file has to spell a home path.
//
// The reload is a CHECK, never a watcher: reload_if_changed reads the file's
// write time and its length and answers whether the file really changed. There
// is no timer and no thread in here; the caller asks when its own loop turns,
// and while a config does not parse the old one stays in force.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// DIRECTORY is the directory under the config home that is this program's.
const DIRECTORY: &str = "aiu-multiplexer";

/// CONFIG_FILE is the name of the config file inside that directory.
const CONFIG_FILE: &str = "config.json";

/// ENV_NAME is the environment value that names a config file outright.
const ENV_NAME: &str = "AIU_MULTIPLEXER_CONFIG";

/// BAKED_DIR is the directory in the state directory the bake writes into.
const BAKED_DIR: &str = "baked";

/// Config is what the client honors: how much of the screen's own furniture is
/// drawn (0 to 3) and whether the tab bar is drawn with it.
#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    /// level is the visual level: 0 hides every row of the screen's own
    /// furniture, 3 is the most the screen draws.
    pub level: u8,
    /// tab_bar says whether the tab bar is drawn at level 1 and above.
    pub tab_bar: bool,
}

impl Config {
    /// defaults answers the config a program with no file at all runs with:
    /// level 2, the mode row, the tab bar, the specifics and the events.
    pub fn defaults() -> Config {
        Config {
            level: 2,
            tab_bar: true,
        }
    }

    /// read answers the config one file holds, with the path in the reason
    /// when it does not hold one.
    pub fn read(path: &Path) -> Result<Config, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|why| format!("{} cannot be read: {}", path.display(), why))?;
        Config::from_json(&text)
            .map_err(|why| format!("{} does not hold a config: {}", path.display(), why))
    }

    /// from_json answers the config a text holds. A key the config does not
    /// know is ignored, so a newer file still runs on an older client; a value
    /// the config does know and cannot use is a reason, not a guess.
    pub fn from_json(text: &str) -> Result<Config, String> {
        let value: Value =
            serde_json::from_str(text).map_err(|why| format!("it is not JSON: {}", why))?;
        Config::from_value(&value)
    }

    /// from_value answers the config one JSON value holds.
    pub fn from_value(value: &Value) -> Result<Config, String> {
        if value.is_object() == false {
            return Err("it is not a JSON object".to_string());
        }
        let mut config = Config::defaults();
        if let Some(found) = value.get("level") {
            let level = found
                .as_u64()
                .ok_or("the level is not a whole number")?;
            if level > 3 {
                return Err(format!("the level {} is higher than 3", level));
            }
            config.level = level as u8;
        }
        if let Some(found) = value.get("tab-bar") {
            config.tab_bar = found
                .as_bool()
                .ok_or("the tab bar is not true or false")?;
        }
        Ok(config)
    }

    /// to_value answers the config as the one object the file holds.
    pub fn to_value(&self) -> Value {
        json!({ "level": self.level, "tab-bar": self.tab_bar })
    }

    /// to_json answers the config as the text a file holds, one key per line,
    /// so a person can read it and change it.
    pub fn to_json(&self) -> String {
        let mut text = serde_json::to_string_pretty(&self.to_value())
            .unwrap_or_else(|_| "{}".to_string());
        text.push('\n');
        text
    }
}

/// Reload answers what one look at the config file found.
pub enum Reload {
    /// Unchanged is the file as it was: nothing to do.
    Unchanged,
    /// Changed carries the config the file now holds: the caller applies it.
    Changed(Config),
    /// Broken carries the reason the file could not be used. The config in
    /// force stays in force.
    Broken(String),
}

/// Stamp is what tells one reading of a file from the next: when it was last
/// written and how long it is. No clock is read here.
#[derive(Clone, Copy, PartialEq)]
struct Stamp {
    mtime: SystemTime,
    len: u64,
}

/// stamp_of answers the stamp of one file, or None when it is not there.
fn stamp_of(path: &Path) -> Option<Stamp> {
    let meta = std::fs::metadata(path).ok()?;
    Some(Stamp {
        mtime: meta.modified().ok()?,
        len: meta.len(),
    })
}

/// config_path answers the config file the environment names: the file named
/// outright, then the config home the machine sets, then the plain one under
/// the home directory. It answers None when the environment names no home at
/// all.
pub fn config_path() -> Option<PathBuf> {
    if let Ok(named) = std::env::var(ENV_NAME) {
        if named.is_empty() == false {
            return Some(PathBuf::from(named));
        }
    }
    if let Ok(home) = std::env::var("XDG_CONFIG_HOME") {
        if home.is_empty() == false {
            return Some(PathBuf::from(home).join(DIRECTORY).join(CONFIG_FILE));
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if home.is_empty() == false {
            return Some(
                PathBuf::from(home)
                    .join(".config")
                    .join(DIRECTORY)
                    .join(CONFIG_FILE),
            );
        }
    }
    None
}

/// baked_path answers where the bake writes the config in one state directory:
/// the same "baked" directory the editor's bake uses.
pub fn baked_path(state_dir: &Path) -> PathBuf {
    state_dir.join(BAKED_DIR).join(CONFIG_FILE)
}

/// ConfigFile is the config in force and the file it follows: the path, what
/// the file looked like when it was read, what it said, and where it came
/// from in words a person reads.
pub struct ConfigFile {
    path: PathBuf,
    stamp: Option<Stamp>,
    config: Config,
    origin: String,
    problem: Option<String>,
}

impl ConfigFile {
    /// start is the config as a program finds it: the file the environment
    /// names, else the last good bake in this state directory, else the
    /// built-in defaults.
    pub fn start(state_dir: &Path) -> ConfigFile {
        ConfigFile::at(state_dir, config_path())
    }

    /// at is start with the sources given, so a caller that knows its config
    /// file needs no environment at all. The baked defaults stay in the state
    /// directory.
    pub fn at(state_dir: &Path, named: Option<PathBuf>) -> ConfigFile {
        let baked = baked_path(state_dir);
        let followed = named.clone().unwrap_or_else(|| baked.clone());

        // 1. the file the environment names, when it is there. A file that
        //    does not parse does not take the program down: the last good
        //    bake answers, and the reason is kept for the message line.
        if let Some(path) = &named {
            if stamp_of(path).is_some() {
                let stamp = stamp_of(path);
                match Config::read(path) {
                    Ok(config) => {
                        return ConfigFile {
                            path: path.clone(),
                            stamp,
                            config,
                            origin: path.display().to_string(),
                            problem: None,
                        }
                    }
                    Err(why) => {
                        let (config, origin) = match Config::read(&baked) {
                            Ok(found) => (
                                found,
                                format!("the last good bake at {}", baked.display()),
                            ),
                            Err(_) => (Config::defaults(), "the built-in defaults".to_string()),
                        };
                        return ConfigFile {
                            path: path.clone(),
                            stamp,
                            config,
                            origin,
                            problem: Some(format!("the config is not used: {}", why)),
                        };
                    }
                }
            }
        }

        // 2. the baked defaults, when a bake has written them.
        if let Ok(config) = Config::read(&baked) {
            return ConfigFile {
                path: baked.clone(),
                stamp: stamp_of(&baked),
                config,
                origin: baked.display().to_string(),
                problem: None,
            };
        }

        // 3. the built-in defaults. The file the environment names is still
        //    followed, so the first write of it is a change like any other.
        ConfigFile {
            path: followed,
            stamp: None,
            config: Config::defaults(),
            origin: "the built-in defaults".to_string(),
            problem: None,
        }
    }

    /// config answers the config in force now.
    pub fn config(&self) -> &Config {
        &self.config
    }

    /// path answers the file this config follows: the one the environment
    /// names when it named one, else the baked defaults.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// origin answers where the config came from, in words the client prints
    /// at its start: a path when a file answered, or the built-in defaults.
    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// problem answers why a config file that is there was not used, so the
    /// client can say it in its message line. None when nothing went wrong.
    pub fn problem(&self) -> Option<&str> {
        self.problem.as_deref()
    }

    /// reload_if_changed looks at the file this config follows and answers
    /// what it found. The file is read only when its write time or its length
    /// is not the one it had when it was read: a file that did not change is
    /// not parsed again. A file that does not parse leaves the config in
    /// force and answers the reason, and the stamp is taken, so the same
    /// unchanged file is reported once and not on every turn of the loop.
    pub fn reload_if_changed(&mut self) -> Reload {
        let now = stamp_of(&self.path);
        if now == self.stamp {
            return Reload::Unchanged;
        }
        let stamp = match now {
            Some(found) => found,
            None => {
                self.stamp = None;
                return Reload::Broken(format!(
                    "the config file {} is not there any more; the config in force stays",
                    self.path.display()
                ));
            }
        };
        self.stamp = Some(stamp);
        match Config::read(&self.path) {
            Ok(config) => {
                self.config = config.clone();
                self.origin = self.path.display().to_string();
                self.problem = None;
                Reload::Changed(config)
            }
            Err(why) => Reload::Broken(format!(
                "{}; the config in force stays",
                why
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// scratch answers a state directory of this test's own, so two tests
    /// never write over each other's file.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mux-config-{}-{}", std::process::id(), name));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("the scratch directory is made");
        dir
    }

    #[test]
    fn the_defaults_are_level_two_with_the_tab_bar() {
        let config = Config::defaults();
        assert_eq!(config.level, 2);
        assert_eq!(config.tab_bar, true);
    }

    #[test]
    fn a_config_holds_the_level_and_the_tab_bar() {
        let config = Config::from_json("{\"level\": 0, \"tab-bar\": false}").expect("it parses");
        assert_eq!(config.level, 0);
        assert_eq!(config.tab_bar, false);
    }

    #[test]
    fn a_key_the_config_does_not_know_is_ignored() {
        let config =
            Config::from_json("{\"level\": 1, \"later\": true}").expect("it parses");
        assert_eq!(config.level, 1);
        assert_eq!(config.tab_bar, true);
    }

    #[test]
    fn a_level_above_three_is_a_reason_and_not_a_clamp() {
        let why = Config::from_json("{\"level\": 7}").expect_err("it is refused");
        assert!(why.contains("higher than 3"), "the reason says why: {}", why);
    }

    #[test]
    fn a_tab_bar_that_is_not_a_boolean_is_a_reason() {
        let why = Config::from_json("{\"tab-bar\": \"yes\"}").expect_err("it is refused");
        assert!(why.contains("true or false"), "the reason says why: {}", why);
    }

    #[test]
    fn a_config_is_written_the_way_it_is_read() {
        let dir = scratch("written");
        let path = dir.join("config.json");
        let written = Config {
            level: 3,
            tab_bar: false,
        };
        fs::write(&path, written.to_json().as_bytes()).expect("the file is written");
        let read = Config::read(&path).expect("it reads back");
        assert_eq!(read, written);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn with_no_file_at_all_the_built_in_defaults_answer() {
        let dir = scratch("empty");
        let named = dir.join("nothing-here.json");
        let config = ConfigFile::at(&dir, Some(named));
        assert_eq!(config.config(), &Config::defaults());
        assert_eq!(config.origin(), "the built-in defaults");
        assert_eq!(config.problem(), None);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_broken_file_at_the_start_falls_back_and_keeps_the_reason() {
        let dir = scratch("broken-start");
        let named = dir.join("config.json");
        fs::write(&named, b"{ not json").expect("the file is written");
        let config = ConfigFile::at(&dir, Some(named));
        assert_eq!(config.config(), &Config::defaults());
        let said = config.problem().unwrap_or("");
        assert!(said.contains("not used"), "the reason says why: {}", said);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_rewritten_file_is_a_change() {
        let dir = scratch("rewritten");
        let named = dir.join("config.json");
        fs::write(&named, b"{\"level\": 2, \"tab-bar\": true}").expect("the file is written");
        let mut config = ConfigFile::at(&dir, Some(named.clone()));
        assert!(matches!(config.reload_if_changed(), Reload::Unchanged));

        let next = Config {
            level: 0,
            tab_bar: false,
        };
        fs::write(&named, next.to_json().as_bytes()).expect("the file is rewritten");
        match config.reload_if_changed() {
            Reload::Changed(found) => assert_eq!(found, next),
            _ => panic!("the change was not seen"),
        }
        assert_eq!(config.config(), &next);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_broken_file_leaves_the_config_in_force_and_says_why() {
        let dir = scratch("broken-reload");
        let named = dir.join("config.json");
        fs::write(&named, b"{\"level\": 1}").expect("the file is written");
        let mut config = ConfigFile::at(&dir, Some(named.clone()));
        let before = config.config().clone();

        fs::write(&named, b"this is not json at all").expect("the file is rewritten");
        match config.reload_if_changed() {
            Reload::Broken(why) => assert!(why.contains("stays"), "the reason says so: {}", why),
            _ => panic!("the broken file was taken for a change"),
        }
        assert_eq!(config.config(), &before);
        // The same file is reported once, not on every turn of the loop.
        assert!(matches!(config.reload_if_changed(), Reload::Unchanged));
        let _ = fs::remove_dir_all(&dir);
    }
}
