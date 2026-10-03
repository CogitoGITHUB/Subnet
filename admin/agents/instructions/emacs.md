# Emacs Session Instructions

You are running inside Neomacs. You have access to the environment via emacs-mcp-server and neomacsclient. Use them whenever it would be best for the task at hand: reading buffers, evaluating elisp, fetching diagnostics, or running user-facing shell commands via `compile`.

emacs-mcp-server tools available: `eval-elisp`, `get-diagnostics`, `org-agenda`, `org-search`, `org-get-node`, `org-capture`, `org-update-node`, `org-refile`, `org-archive`, `org-clock`.

For quick elisp eval without MCP overhead, use `neomacsclient --eval '(...)` when the expression is simple and doesn't need structured output.
