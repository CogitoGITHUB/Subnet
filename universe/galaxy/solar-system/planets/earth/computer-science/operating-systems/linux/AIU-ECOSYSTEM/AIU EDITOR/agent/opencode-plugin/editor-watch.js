// One job: watch the editor's event feed and print what came — read only.
//
// The feed is the journal of a file: one record per line, flushed as it
// is written. The plugin reads the feed and prints the records, and it
// NEVER writes: the editor owns the file, and the plugin only looks.
// The gate proves that by scanning this source for a write call and by
// running it against a file and comparing the file before and after.
//
// Usage: node editor-watch.js FEED [FROM]
//
// FROM is the first record to print, counted from 1. Without it, every
// record is printed.

const fs = require("fs");

// readFeed answers the records of the feed file: its lines, in order.
// A feed that is not there has no records, and that is not an error:
// the watcher has nothing to say yet.
function readFeed(path) {
  if (!fs.existsSync(path)) {
    return [];
  }
  const text = fs.readFileSync(path, "utf8");
  return text.split("\n").filter((line) => line !== "");
}

// printRecords prints the records from the given number on, one per line.
function printRecords(records, from) {
  records.slice(from - 1).forEach((record) => {
    process.stdout.write(record + "\n");
  });
}

// main reads the feed and prints what is there.
function main() {
  const path = process.argv[2];
  const from = process.argv[3] ? Number(process.argv[3]) : 1;
  if (!path) {
    process.stderr.write("the watcher needs the feed file\n");
    process.exit(2);
  }
  printRecords(readFeed(path), from);
}

main();
