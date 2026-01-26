module.exports = {
  "content": [
    "src/server.zig",
    "src/server/*.js",
    "src/layouts/base.html"
  ],
  "css": [
    "src/server/dist/main.css"
  ],
  "output": "src/server/dist/main.css",
  "tailwind": false,
  "variables": true,
  "keyframes": true,
  "fontFace": true,
  "minify": false,
  "backup": false,
  "report": "reports/prune.json",
  "watch": false
}
