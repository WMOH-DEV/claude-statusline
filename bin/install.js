#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const STATUSLINE_FILE = path.join(CLAUDE_DIR, "statusline-command.sh");
const SOURCE_FILE = path.join(__dirname, "statusline.sh");

const BOLD = "\x1b[1m";
const GREEN = "\x1b[92m";
const YELLOW = "\x1b[93m";
const RED = "\x1b[91m";
const CYAN = "\x1b[96m";
const DIM = "\x1b[2m";
const R = "\x1b[0m";

function printBanner() {
  console.log(`
${CYAN}${BOLD}  ┌─────────────────────────────────────┐
  │   Claude Code Statusline Installer   │
  └─────────────────────────────────────┘${R}
`);
}

function uninstall() {
  printBanner();
  console.log(`${YELLOW}Uninstalling...${R}\n`);

  // Remove statusline script
  if (fs.existsSync(STATUSLINE_FILE)) {
    fs.unlinkSync(STATUSLINE_FILE);
    console.log(`${GREEN}✓${R} Removed ${DIM}${STATUSLINE_FILE}${R}`);
  }

  // Remove statusLine from settings
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
      if (settings.statusLine) {
        delete settings.statusLine;
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
        console.log(`${GREEN}✓${R} Removed statusLine from ${DIM}${SETTINGS_FILE}${R}`);
      }
    } catch {
      console.log(`${RED}✗${R} Could not update settings.json`);
    }
  }

  // Remove cache
  const cacheFile = "/tmp/claude/statusline-usage-cache.json";
  if (fs.existsSync(cacheFile)) {
    fs.unlinkSync(cacheFile);
    console.log(`${GREEN}✓${R} Removed cache`);
  }

  console.log(`\n${GREEN}${BOLD}Uninstalled!${R} Restart Claude Code to apply.\n`);
}

function install() {
  printBanner();

  // Ensure .claude directory exists
  if (!fs.existsSync(CLAUDE_DIR)) {
    fs.mkdirSync(CLAUDE_DIR, { recursive: true });
    console.log(`${GREEN}✓${R} Created ${DIM}${CLAUDE_DIR}${R}`);
  }

  // Copy statusline script
  if (!fs.existsSync(SOURCE_FILE)) {
    console.log(`${RED}✗${R} Source file not found: ${SOURCE_FILE}`);
    process.exit(1);
  }

  fs.copyFileSync(SOURCE_FILE, STATUSLINE_FILE);
  fs.chmodSync(STATUSLINE_FILE, 0o755);
  console.log(`${GREEN}✓${R} Installed statusline script to ${DIM}${STATUSLINE_FILE}${R}`);

  // Update settings.json
  let settings = {};
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
    } catch {
      console.log(`${YELLOW}⚠${R} Could not parse existing settings.json, creating backup`);
      fs.copyFileSync(SETTINGS_FILE, SETTINGS_FILE + ".bak");
      settings = {};
    }
  }

  // Back up old statusline if different
  if (settings.statusLine && settings.statusLine.command && !settings.statusLine.command.includes("statusline-command.sh")) {
    console.log(`${YELLOW}⚠${R} Backing up previous statusLine command: ${DIM}${settings.statusLine.command}${R}`);
  }

  settings.statusLine = {
    type: "command",
    command: `bash "${STATUSLINE_FILE}"`
  };

  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
  console.log(`${GREEN}✓${R} Updated ${DIM}${SETTINGS_FILE}${R}`);

  // Print summary
  console.log(`
${GREEN}${BOLD}Installed!${R} Restart Claude Code to see your new statusline.

${BOLD}What you'll see:${R}
${DIM}Line 1:${R} 📁 project │ 🤖 Opus 4.6 │ 🌿 main │ 💰 $0.42 │ ⏱ 1h 23m │ 📊 42% ctx
${DIM}Line 2:${R} ⏳ 5h: ●●●●●○○○○○ 48% (2h 30m) │ 📅 7d: ●●●●○○○○○○ 40% │ 💳 $16/$20

${DIM}To uninstall:${R} npx @wael-mohamed/claude-statusbar --uninstall
`);
}

// Parse args
const args = process.argv.slice(2);

if (args.includes("--uninstall") || args.includes("-u")) {
  uninstall();
} else if (args.includes("--help") || args.includes("-h")) {
  printBanner();
  console.log(`${BOLD}Usage:${R}
  npx @wael-mohamed/claude-statusbar            Install statusline
  npx @wael-mohamed/claude-statusbar --uninstall Remove statusline
  npx @wael-mohamed/claude-statusbar --help      Show this help
`);
} else {
  install();
}
