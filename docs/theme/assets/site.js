// SPDX-License-Identifier: GPL-3.0-or-later
// Script of the documentation site: search, copy buttons, the table of
// contents, the theme switch and the navigation on small screens.
(function () {
  "use strict";

  var doc = document.documentElement;
  var body = document.body;

  function store(key, value) {
    try {
      if (value === undefined) return localStorage.getItem(key);
      localStorage.setItem(key, value);
    } catch (error) {
      return null;
    }
  }

  // ---- sections of the top bar ------------------------------------------
  document.querySelectorAll(".top-nav a").forEach(function (link) {
    if (link.dataset.section === body.dataset.section) link.classList.add("on");
  });

  // ---- theme --------------------------------------------------------------
  var themeButton = document.querySelector(".theme-btn");
  if (themeButton) {
    themeButton.addEventListener("click", function () {
      var dark = doc.dataset.theme
        ? doc.dataset.theme === "dark"
        : window.matchMedia("(prefers-color-scheme: dark)").matches;
      doc.dataset.theme = dark ? "light" : "dark";
      store("theme", doc.dataset.theme);
    });
  }

  // ---- navigation on small screens ------------------------------------
  var menuButton = document.querySelector(".menu-btn");
  if (menuButton) {
    menuButton.addEventListener("click", function () {
      var open = body.classList.toggle("nav-open");
      menuButton.setAttribute("aria-expanded", String(open));
    });
    document.querySelector(".main").addEventListener("click", function () {
      body.classList.remove("nav-open");
      menuButton.setAttribute("aria-expanded", "false");
    });
  }

  // ---- copy buttons -------------------------------------------------------
  document.querySelectorAll(".code").forEach(function (block) {
    var button = block.querySelector(".copy");
    var code = block.querySelector("code");
    if (!button || !code) return;
    button.addEventListener("click", function () {
      // In a terminal block, copy the commands without the prompts and
      // without the output.
      var text = code.innerText;
      if (code.querySelector(".p")) {
        text = text
          .split("\n")
          .filter(function (line) { return /^(\$|>) /.test(line); })
          .map(function (line) { return line.replace(/^(\$|>) /, ""); })
          .join("\n");
      }
      var done = function () {
        button.textContent = "Copied";
        button.classList.add("done");
        setTimeout(function () {
          button.textContent = "Copy";
          button.classList.remove("done");
        }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () {});
      }
    });
  });

  // ---- table of contents: mark the section in view ----------------------
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
  if (tocLinks.length && "IntersectionObserver" in window) {
    var headings = tocLinks
      .map(function (link) { return document.getElementById(link.hash.slice(1)); })
      .filter(Boolean);
    var mark = function () {
      var current = headings[0];
      headings.forEach(function (heading) {
        if (heading.getBoundingClientRect().top < 120) current = heading;
      });
      tocLinks.forEach(function (link) {
        link.classList.toggle("on", current && link.hash === "#" + current.id);
      });
    };
    var ticking = false;
    window.addEventListener("scroll", function () {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(function () { mark(); ticking = false; });
    }, { passive: true });
    mark();
  }

  // ---- search -------------------------------------------------------------
  var panel = document.querySelector(".search");
  var input = panel && panel.querySelector("input");
  var results = panel && panel.querySelector(".search-results");
  var records = null;
  var selected = 0;

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function markWords(text, words) {
    var html = escapeHtml(text);
    words.forEach(function (word) {
      var pattern = escapeHtml(word).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      html = html.replace(new RegExp("(" + pattern + ")(?![^<]*>)", "gi"), "<mark>$1</mark>");
    });
    return html;
  }

  function excerpt(text, words) {
    var lower = text.toLowerCase();
    var at = -1;
    words.forEach(function (word) {
      var index = lower.indexOf(word);
      if (index >= 0 && (at < 0 || index < at)) at = index;
    });
    var start = Math.max(0, at - 50);
    return (start > 0 ? "… " : "") + text.slice(start, start + 170);
  }

  function search(query) {
    var words = query.toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length || !records) return [];
    return records
      .map(function (record) {
        var title = (record.heading || record.page).toLowerCase();
        var page = record.page.toLowerCase();
        var text = record.text.toLowerCase();
        var score = 0;
        for (var i = 0; i < words.length; i++) {
          var word = words[i];
          var hit = 0;
          if (title.indexOf(word) >= 0) hit += 10;
          if (page.indexOf(word) >= 0) hit += 4;
          if (text.indexOf(word) >= 0) hit += 1;
          if (!hit) return null;
          score += hit;
        }
        if (!record.heading) score += 2;
        return { record: record, score: score };
      })
      .filter(Boolean)
      .sort(function (a, b) { return b.score - a.score; })
      .slice(0, 12)
      .map(function (item) { return { record: item.record, words: words }; });
  }

  function render() {
    var query = input.value.trim();
    var found = search(query);
    selected = 0;
    if (!query) {
      results.innerHTML = "";
      return;
    }
    if (!found.length) {
      results.innerHTML = '<div class="r-none">No result for “' + escapeHtml(query) + "”.</div>";
      return;
    }
    results.innerHTML = found
      .map(function (item, index) {
        var record = item.record;
        return (
          '<a role="option" href="' + record.url + '"' + (index === 0 ? ' class="on"' : "") + ">" +
          '<span class="r-title">' + markWords(record.heading || record.page, item.words) + "</span>" +
          (record.heading ? '<span class="r-page">' + escapeHtml(record.page) + "</span>" : "") +
          '<span class="r-text">' + markWords(excerpt(record.text, item.words), item.words) + "</span></a>"
        );
      })
      .join("");
  }

  function select(step) {
    var links = results.querySelectorAll("a");
    if (!links.length) return;
    links[selected].classList.remove("on");
    selected = (selected + step + links.length) % links.length;
    links[selected].classList.add("on");
    links[selected].scrollIntoView({ block: "nearest" });
  }

  function openSearch() {
    panel.hidden = false;
    input.value = "";
    results.innerHTML = "";
    input.focus();
    if (!records) {
      fetch("assets/search.json")
        .then(function (response) { return response.json(); })
        .then(function (data) { records = data; render(); })
        .catch(function () {
          results.innerHTML = '<div class="r-none">The search index did not load.</div>';
        });
    }
  }

  function closeSearch() {
    panel.hidden = true;
  }

  if (panel) {
    document.querySelector(".search-btn").addEventListener("click", openSearch);
    input.addEventListener("input", render);
    panel.addEventListener("click", function (event) {
      if (event.target === panel) closeSearch();
    });
    document.addEventListener("keydown", function (event) {
      var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName);
      if (panel.hidden) {
        if ((event.key === "/" && !typing) || (event.key === "k" && (event.metaKey || event.ctrlKey))) {
          event.preventDefault();
          openSearch();
        }
        return;
      }
      if (event.key === "Escape") closeSearch();
      else if (event.key === "ArrowDown") { event.preventDefault(); select(1); }
      else if (event.key === "ArrowUp") { event.preventDefault(); select(-1); }
      else if (event.key === "Enter") {
        var link = results.querySelectorAll("a")[selected];
        if (link) { event.preventDefault(); closeSearch(); window.location.href = link.href; }
      } else if (event.key === "k" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        closeSearch();
      }
    });
  }
})();
