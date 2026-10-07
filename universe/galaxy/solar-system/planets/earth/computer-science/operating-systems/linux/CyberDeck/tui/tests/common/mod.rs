//! Shared helpers for integration tests.

use tui::index::Index;
use tui::model::IndexDoc;

pub fn load_fixture() -> Index {
    let doc: IndexDoc =
        serde_json::from_str(include_str!("../fixtures/small.json")).expect("fixture parses");
    Index::from_doc(doc, 0).expect("fixture validates")
}
