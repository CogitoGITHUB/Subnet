//! tui entry point: terminal setup, event loop, clean shutdown.

use std::path::PathBuf;
use std::time::Duration;

use clap::Parser;
use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use ratatui::DefaultTerminal;

use tui::app::App;
use tui::{ui, VERSION};

#[derive(Parser, Debug)]
#[command(
    name = "tui",
    version = VERSION,
    about = "Package explorer for the CyberDeck package manager",
    long_about = "Reads the CyberDeck package snapshot, caches it locally,\nand offers fuzzy search, package details, and dependency/reverse-dependency\ntrees over every known package."
)]
struct Cli {
    /// Rebuild the package index even if the cache is fresh
    #[arg(short, long, global = true)]
    rebuild: bool,

    /// Path to the package snapshot JSON file
    ///
    /// Defaults to $CYBERDECK_SNAPSHOT, else ./snapshot.json
    #[arg(long, global = true)]
    snapshot: Option<PathBuf>,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let snapshot = tui::indexer::resolve_snapshot(cli.snapshot);
    run_tui(cli.rebuild, snapshot)
}

fn run_tui(rebuild: bool, snapshot: PathBuf) -> anyhow::Result<()> {
    let mut app = App::new(rebuild, snapshot);
    let mut terminal: DefaultTerminal = ratatui::init();

    // Restore the terminal even if a panic escapes the event loop.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        ratatui::restore();
        default_hook(info);
    }));

    let result = run(&mut terminal, &mut app);

    ratatui::restore();
    app.shutdown();
    result
}

fn run(terminal: &mut DefaultTerminal, app: &mut App) -> anyhow::Result<()> {
    app.size = terminal
        .size()
        .map(|s| (s.width, s.height))
        .unwrap_or((80, 24));
    loop {
        let poll = if app.animating() {
            Duration::from_millis(33)
        } else {
            Duration::from_millis(250)
        };

        if event::poll(poll)? {
            match event::read()? {
                Event::Key(key) => {
                    // Ignore release/repeat events; only Press matters.
                    if key.kind != crossterm::event::KeyEventKind::Press {
                        continue;
                    }
                    // Shift+Tab arrives as BackTab on most terminals.
                    if key.code == KeyCode::BackTab {
                        app.on_key(crossterm::event::KeyEvent::new(
                            KeyCode::Tab,
                            KeyModifiers::SHIFT,
                        ));
                    } else {
                        app.on_key(key);
                    }
                }
                Event::Resize(w, h) => {
                    app.size = (w, h);
                    app.dirty = true;
                }
                _ => {}
            }
        }

        app.on_tick();
        app.clamp_cursor();
        if app.pump_events() || app.pump_search() {
            app.dirty = true;
        }

        if app.quit {
            break;
        }

        if app.dirty || app.animating() {
            terminal.draw(|f| ui::draw(f, app))?;
            app.dirty = false;
        }
    }
    Ok(())
}
