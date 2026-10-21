// One job: the bake — the config in force becomes the baked defaults in the
// state directory, and it is kept as the last good only when it reads back as
// the config that was written.
//
// The baked file is generated and says so: it is JSON, so the generator line is
// a key of its own, and the config reader ignores a key it does not know. The
// baked defaults are what a client with no user config starts from, so the bake
// is how a working config travels into a program that reads no file at startup.
//
// The check is made here and it is a read-back, not a promise: a bake that
// cannot be read back as the config it came from is not good, and the last good
// stays the last good (last_good.rs).
//
// The rebuild is MANUAL: the owner runs mux-bake when they decide, it may run
// long, and it says what it did when it is done. There is no timer and no
// watcher anywhere in here.

use super::config::{baked_path, Config, ConfigFile};
use super::last_good;
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Bake is what the bake did: the path it wrote, whether that file is good,
/// the reason when it is not, and where the last good one stands.
pub struct Bake {
    /// path is the baked defaults file this bake wrote, or tried to write.
    pub path: PathBuf,
    /// good says whether the file read back as the config that was asked for.
    pub good: bool,
    /// reason is why the bake is not good, in a sentence a person reads.
    pub reason: Option<String>,
    /// last_good is the path of the last good bake after this one ran.
    pub last_good: Option<PathBuf>,
}

impl Bake {
    /// report answers what the bake did, one line each: the path, whether it is
    /// good and why when it is not, and where the last good one stands.
    pub fn report(&self) -> Vec<String> {
        let mut lines: Vec<String> = Vec::new();
        lines.push(format!("the baked defaults: {}", self.path.display()));
        if self.good {
            lines.push(
                "good: the bake was read back, and it is the config that was asked for"
                    .to_string(),
            );
            lines.push(format!("the last good is now: {}", self.path.display()));
        } else {
            let why = self
                .reason
                .clone()
                .unwrap_or_else(|| "the bake gave no reason, which is a fault of its own".to_string());
            lines.push(format!("not good: {}", why));
            match &self.last_good {
                Some(path) => lines.push(format!("the last good stays: {}", path.display())),
                None => lines.push(
                    "the last good: none yet, and this bake did not become one".to_string(),
                ),
            }
        }
        lines
    }
}

/// baked_text answers the text of the baked file: the config as first-class
/// defaults, with the line that says the file was generated.
fn baked_text(config: &Config) -> String {
    let mut value = config.to_value();
    if let Value::Object(fields) = &mut value {
        fields.insert(
            "generated-by".to_string(),
            Value::from("mux-bake — the config as first-class defaults; do not edit by hand"),
        );
    }
    let mut text = serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_string());
    text.push('\n');
    text
}

/// not_good answers a bake that did not happen, with the reason and the last
/// good record as it stands.
fn not_good(state_dir: &Path, why: String) -> Bake {
    Bake {
        path: baked_path(state_dir),
        good: false,
        reason: Some(why),
        last_good: last_good::last_good(state_dir),
    }
}

/// bake writes the config as the baked defaults, reads the file back, and
/// records it as the last good only when it reads back as the config that was
/// written. It answers the path, whether it is good, why not, and where the
/// last good one stands.
pub fn bake(state_dir: &Path, config: &Config) -> Bake {
    let path = baked_path(state_dir);
    if let Some(parent) = path.parent() {
        if let Err(why) = std::fs::create_dir_all(parent) {
            return not_good(
                state_dir,
                format!(
                    "the baked directory {} cannot be made: {}",
                    parent.display(),
                    why
                ),
            );
        }
    }

    let text = baked_text(config);
    if let Err(why) = std::fs::write(&path, text.as_bytes()) {
        return not_good(
            state_dir,
            format!("{} cannot be written: {}", path.display(), why),
        );
    }

    // The check: the file read back, parsed, and compared with what was
    // written. A bake that cannot be read back is not a bake.
    let back = match last_good::read_text(&path) {
        Ok(text) => text,
        Err(why) => return not_good(state_dir, why),
    };
    match Config::from_json(&back) {
        Err(why) => not_good(
            state_dir,
            format!("{} does not read back as a config: {}", path.display(), why),
        ),
        Ok(found) if found != *config => not_good(
            state_dir,
            format!(
                "{} reads back as another config than the one that was written",
                path.display()
            ),
        ),
        Ok(_) => match last_good::keep_last_good(state_dir, &path) {
            Ok(()) => Bake {
                path: path.clone(),
                good: true,
                reason: None,
                last_good: Some(path),
            },
            Err(why) => not_good(
                state_dir,
                format!("the bake is good and it could not be recorded: {}", why),
            ),
        },
    }
}

/// bake_file reads the config one file holds and bakes it. A file that does not
/// hold a config is refused before anything is written: nothing is baked on a
/// guess, and the last good stays.
pub fn bake_file(state_dir: &Path, source: &Path) -> Bake {
    match Config::read(source) {
        Ok(config) => bake(state_dir, &config),
        Err(why) => not_good(
            state_dir,
            format!(
                "{}; nothing was baked and the last good stays" ,
                why
            ),
        ),
    }
}

/// bake_in_force bakes the config the program would run with right now: the
/// file the environment names, else the last good bake, else the built-in
/// defaults.
pub fn bake_in_force(state_dir: &Path) -> Bake {
    let in_force = ConfigFile::start(state_dir);
    bake(state_dir, in_force.config())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// scratch answers a state directory of this test's own.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mux-bake-{}-{}", std::process::id(), name));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("the scratch directory is made");
        dir
    }

    #[test]
    fn a_good_bake_is_written_and_becomes_the_last_good() {
        let dir = scratch("good");
        let config = Config {
            level: 3,
            tab_bar: false,
        };
        let baked = bake(&dir, &config);
        assert_eq!(baked.good, true);
        assert_eq!(baked.reason, None);
        assert_eq!(baked.last_good, Some(baked.path.clone()));
        assert_eq!(last_good::last_good(&dir), Some(baked.path.clone()));

        let text = last_good::read_text(&baked.path).expect("the baked file reads");
        assert_eq!(Config::from_json(&text).expect("it parses"), config);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_baked_file_says_it_was_generated() {
        let dir = scratch("generated");
        let baked = bake(&dir, &Config::defaults());
        let text = last_good::read_text(&baked.path).expect("the baked file reads");
        assert!(text.contains("generated-by"), "the file says so: {}", text);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_second_good_bake_takes_the_last_good() {
        let dir = scratch("second");
        let first = bake(&dir, &Config::defaults());
        let second = bake(
            &dir,
            &Config {
                level: 0,
                tab_bar: false,
            },
        );
        assert_eq!(first.path, second.path);
        assert_eq!(second.good, true);
        assert_eq!(last_good::last_good(&dir), Some(second.path));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_config_that_does_not_parse_is_not_baked() {
        let dir = scratch("refused");
        let good = bake(&dir, &Config::defaults());
        assert_eq!(good.good, true);
        let before = last_good::read_text(&good.path).expect("the bake reads");

        let source = dir.join("broken.json");
        fs::write(&source, b"{ nope").expect("the broken file is written");
        let refused = bake_file(&dir, &source);
        assert_eq!(refused.good, false);
        let why = refused.reason.unwrap_or_default();
        assert!(why.contains("does not hold a config"), "the reason says why: {}", why);
        assert_eq!(refused.last_good, Some(good.path.clone()));

        let after = last_good::read_text(&good.path).expect("the bake still reads");
        assert_eq!(before, after);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_report_says_what_the_bake_did() {
        let dir = scratch("report");
        let baked = bake(&dir, &Config::defaults());
        let lines = baked.report();
        assert!(lines[0].contains("the baked defaults"), "the path comes first: {:?}", lines);
        assert!(lines[1].starts_with("good:"), "the verdict comes next: {:?}", lines);
        assert!(lines[2].contains("the last good is now"), "the record comes last: {:?}", lines);
        let _ = fs::remove_dir_all(&dir);
    }
}
