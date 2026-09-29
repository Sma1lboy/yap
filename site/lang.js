// Language toggle for the site's subpages (index.html has the same logic inline). The choice is shared through localStorage.
(function () {
  var root = document.documentElement, toggle = document.getElementById("lang-toggle");
  function applyLang(lang) {
    root.setAttribute("data-lang", lang);
    root.setAttribute("lang", lang === "zh-Hans" ? "zh-Hans" : "en");
    toggle.textContent = lang === "zh-Hans" ? "English" : "中文";
  }
  var saved = null;
  try { saved = localStorage.getItem("yap-site-lang"); } catch (e) {}
  applyLang(saved || ((navigator.language || "").toLowerCase().indexOf("zh") === 0 ? "zh-Hans" : "en"));
  toggle.addEventListener("click", function () {
    var next = root.getAttribute("data-lang") === "zh-Hans" ? "en" : "zh-Hans";
    applyLang(next);
    try { localStorage.setItem("yap-site-lang", next); } catch (e) {}
  });
})();
