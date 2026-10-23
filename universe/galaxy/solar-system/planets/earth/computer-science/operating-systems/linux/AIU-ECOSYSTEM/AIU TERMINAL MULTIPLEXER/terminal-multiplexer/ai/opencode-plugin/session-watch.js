// One job: watch a session's log and print what came — read only.
//
// The log is the record of a session: one JSON object per line, flushed as
// it is written. The plugin reads the log and prints the records, and it
// NEVER writes: the holder owns the log, and the plugin only looks.
//
// Usage: node session-watch.js LOG [FROM]
//
// FROM is the first record to print, counted from 1. Without it, every
// record is printed.

const fs = require("fs");

// readLog answers the records of the log file: its lines, in order.
// A log that is not there has no records, and that is not an error:
// the watcher has nothing to say yet.
function readLog(path) {
  if (!fs.existsSync(path)) {
    return [];
  }
  const body = fs.readFileSync(path, "utf8");
  return body
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "");
}

// oneLine answers what one record says, in one line: the kind, the what and
// the text the shell wrote. A record that is not a record is named as such.
function oneLine(line) {
  let record;
  try {
    record = JSON.parse(line);
  } catch (why) {
    return `not a record: ${line}`;
  }
  const kind = record.kind || "record";
  const what = record.what || "";
  const text = record.outputs && record.outputs.text ? record.outputs.text : "";
  const head = `${record.seq || "?"} ${kind} ${what}`;
  return text === "" ? head : `${head} :: ${text.replace(/\n/g, "\\n")}`;
}

// main prints the records of the log, from the one asked for.
function main(argv) {
  const path = argv[0];
  if (!path) {
    console.error("usage: node session-watch.js LOG [FROM]");
    process.exit(2);
  }
  const from = argv[1] ? Number(argv[1]) : 1;
  const records = readLog(path);
  records.slice(Math.max(0, from - 1)).forEach((line) => {
    console.log(oneLine(line));
  });
}

main(process.argv.slice(2));
