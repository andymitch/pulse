import AppKit

private let exportScript = """
function run(argv) {
  const days = Number(argv[0]);
  const Mail = Application('Mail');
  const cutoff = new Date(Date.now() - days * 86400000);
  const msgs = Mail.inbox.messages.whose({ dateReceived: { _greaterThan: cutoff } })();
  const out = msgs.map(m => {
    let excerpt = '';
    try { excerpt = (m.content() || '').replace(/\\s+/g, ' ').slice(0, 500); } catch (e) {}
    return {
      subject: m.subject(),
      from: m.sender(),
      date: m.dateReceived().toISOString(),
      read: m.readStatus(),
      url: 'message://%3C' + encodeURIComponent(m.messageId()) + '%3E',
      excerpt: excerpt,
    };
  });
  out.sort((a, b) => b.date.localeCompare(a.date));
  return JSON.stringify(out.slice(0, 80));
}
"""

var mailRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty }

func exportMail(days: Int, to file: URL) throws {
    let script = file.deletingLastPathComponent().appendingPathComponent("export-mail.js")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try exportScript.write(to: script, atomically: true, encoding: .utf8)
    let json = try shell("osascript -l JavaScript '\(script.path)' \(days)")
    try json.write(to: file, atomically: true, encoding: .utf8)
}
