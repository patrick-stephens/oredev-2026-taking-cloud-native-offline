const express = require("express");

const app = express();

app.get("/healthz", (_request, response) => {
  response.json({ status: "ok", dependency: "Express" });
});

module.exports = app;
