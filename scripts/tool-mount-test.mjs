// Real-API acceptance test for the analyze_image tool (Door 2).
// Mounts the installed plugin with a fake ctx (captures the registered tool),
// then executes it against the real local vision model with a real image file.
//
// usage: node tool-mount-test.mjs <image-path>
// env:   VISION_PLUGIN (default C:/Users/EDY/.dsh/plugins/vision/index.js)
//        VISION_FAST_URL / VISION_FAST_MODEL (default Ollama qwen2.5vl:3b)
const pluginPath =
  process.env.VISION_PLUGIN || "C:/Users/EDY/.dsh/plugins/vision/index.js";
const imagePath = process.argv[2];
if (!imagePath) {
  console.error("usage: node tool-mount-test.mjs <image-path>");
  process.exit(2);
}

process.env.VISION_FAST_URL =
  process.env.VISION_FAST_URL || "http://127.0.0.1:11434/v1/chat/completions";
process.env.VISION_FAST_MODEL =
  process.env.VISION_FAST_MODEL || "qwen2.5vl:3b";

const specifier = "file:///" + pluginPath.replace(/\\/g, "/").replace(/^\/+/, "");
const plugin = await import(specifier);

let tool = null;
// Faithful Cordis-like ctx: accessing a property not declared in `inject`
// throws, exactly like the real harness. This catches missing-inject
// regressions (e.g. ctx.fs without "fs" in the inject list).
const required = Array.isArray(plugin.inject) ? plugin.inject : [];
const ctx = new Proxy(
  {
    tools: {
      register: (t) => {
        tool = t;
      },
    },
    fs: {
      readFile: async (p) => {
        const { readFile } = await import("node:fs/promises");
        return readFile(p);
      },
    },
  },
  {
    get(target, prop) {
      if (!(prop in target) && !required.includes(prop)) {
        throw new Error(`cannot get property "${String(prop)}" without inject`);
      }
      return target[prop];
    },
  }
);
plugin.apply(ctx, {});

if (!tool) {
  console.error("FAIL: analyze_image was not registered by the plugin");
  process.exit(1);
}

const out = await tool.execute({
  path: imagePath,
  backend: "fast",
  prompt: "Describe this image in one short sentence. Start with 'The image is'.",
});

const text = Array.isArray(out)
  ? out
      .filter((b) => b && b.type === "text" && typeof b.text === "string")
      .map((b) => b.text)
      .join("\n")
  : String(out ?? "");
if (!text.trim()) {
  console.error("FAIL: tool returned an empty result");
  process.exit(1);
}

console.log("RESULT:", text.trim());
console.log("TOOL OK");
