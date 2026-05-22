(function () {
  function requireGlobal(name) {
    var value = window[name];
    if (!value) {
      throw new Error(name + " is not loaded");
    }
    return value;
  }

  function terminalConstructor() {
    if (window.Terminal) {
      return window.Terminal;
    }
    if (window.XTerm && window.XTerm.Terminal) {
      return window.XTerm.Terminal;
    }
    throw new Error("xterm.js is not loaded");
  }

  function fitAddonConstructor() {
    var addon = requireGlobal("FitAddon");
    if (addon.FitAddon) {
      return addon.FitAddon;
    }
    return addon;
  }

  function create(elementId, statusCallback) {
    function report(status) {
      if (statusCallback) {
        statusCallback(status);
      }
    }

    report("locating host");
    var element = document.getElementById(elementId);
    if (!element) {
      report("host missing");
      throw new Error("Terminal host element not found: " + elementId);
    }

    element.textContent = "Starting terminal...";
    element.style.backgroundColor = "#0b0f12";
    element.style.boxSizing = "border-box";
    element.style.color = "#d7dde2";
    element.style.height = "100%";
    element.style.minHeight = "240px";
    element.style.overflow = "hidden";
    element.style.position = "relative";
    element.style.width = "100%";

    report("loading xterm globals");
    var Terminal = terminalConstructor();
    var FitAddon = fitAddonConstructor();
    var fitAddon = new FitAddon();
    var inputHandler = null;
    var terminal = new Terminal({
      allowProposedApi: false,
      convertEol: true,
      cursorBlink: true,
      cursorStyle: "block",
      fontFamily: '"JetBrains Mono", "SFMono-Regular", Consolas, monospace',
      fontSize: 14,
      scrollback: 10000,
      theme: {
        background: "#0b0f12",
        foreground: "#d7dde2",
        cursor: "#f2c14e",
        selectionBackground: "#315c72"
      }
    });

    element.textContent = "";
    terminal.loadAddon(fitAddon);
    terminal.open(element);
    element.querySelectorAll(".terminal, .xterm").forEach(function (node) {
      node.style.height = "100%";
      node.style.width = "100%";
    });
    fitAddon.fit();
    report("opened " + terminal.cols + "x" + terminal.rows);
    terminal.onData(function (data) {
      if (inputHandler) {
        inputHandler(data);
      }
    });

    var resizeObserver = new ResizeObserver(function () {
      fitAddon.fit();
    });
    resizeObserver.observe(element);

    return {
      dispose: function () {
        resizeObserver.disconnect();
        terminal.dispose();
      },
      fit: function () {
        fitAddon.fit();
        report("opened " + terminal.cols + "x" + terminal.rows);
      },
      focus: function () {
        terminal.focus();
      },
      setInputHandler: function (handler) {
        inputHandler = handler;
      },
      write: function (data) {
        terminal.write(data);
      }
    };
  }

  window.argusTerminalBridge = {
    create: create
  };
})();
