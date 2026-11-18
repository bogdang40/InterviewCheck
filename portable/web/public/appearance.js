// Apply the browser's saved preference before the workspace is displayed.
;(function () {
  function apply() {
    try {
      var theme = localStorage.getItem("interviewcheck.appearance")
      document.documentElement.dataset.theme = theme === "system" || theme === "light" ? theme : "dark"
    } catch {
      document.documentElement.dataset.theme = "dark"
    }
  }
  apply()
  window.addEventListener("storage", function (event) {
    if (event.key === "interviewcheck.appearance" || event.key === null) {
      apply()
      window.dispatchEvent(new Event("interviewcheck:appearance"))
    }
  })
})()
