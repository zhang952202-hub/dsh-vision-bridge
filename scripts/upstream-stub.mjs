// Upstream stub for vision-bridge acceptance tests.
// Acts as the "text-only brain": records every chat completion body it
// receives and answers with a canned reply. The vision shim must rewrite
// image blocks into [Image: ...] text BEFORE this stub sees them.
import http from "node:http";
import fs from "node:fs";

const port = Number(process.env.STUB_PORT || 8911);
const recordPath = process.env.RECORD_PATH || "stub-request.json";

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    if (req.url.startsWith("/v1/models")) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ object: "list", data: [{ id: "stub-text-model" }] }));
      return;
    }
    fs.writeFileSync(recordPath, body);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        id: "stub-1",
        object: "chat.completion",
        model: "stub-text-model",
        choices: [
          {
            index: 0,
            message: { role: "assistant", content: "stub upstream reply" },
            finish_reason: "stop",
          },
        ],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      })
    );
  });
});

server.listen(port, "127.0.0.1", () =>
  console.log(`upstream-stub listening on http://127.0.0.1:${port}`)
);
