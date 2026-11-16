// Duo Dock product page. No dependencies, no tracking, nothing stored.
(function () {
  "use strict";

  // ---------------------------------------------------------------------------
  // Payments config.
  // TODO (payments): paste your Stripe Payment Link URLs here (Stripe dashboard →
  // Payment Links → Create). Leave them empty and the form stays in demo mode.
  // See web/dock/README.md → "Add Stripe Payment Links".
  // ---------------------------------------------------------------------------
  var STRIPE_LINKS = {
    AU: "", // e.g. "https://buy.stripe.com/xxxxxxxx"  (A$69 launch, then A$79, shipping included)
    US: ""  // e.g. "https://buy.stripe.com/yyyyyyyy"  (US$49 + US$12 shipping as a second line item)
  };

  // Campaign tags from the link that brought the visitor (e.g. from the Duo Dash app:
  // ?utm_source=duodash&utm_medium=app&utm_campaign=onboarding). Kept in memory only and
  // passed to Stripe as client_reference_id so sales can be attributed.
  var params = new URLSearchParams(window.location.search);
  var utm = ["utm_source", "utm_medium", "utm_campaign"]
    .map(function (k) { return (params.get(k) || "").replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 40); })
    .filter(Boolean)
    .join("__");

  // --- Mount option tabs ------------------------------------------------------
  var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
  function selectTab(tab) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute("aria-selected", on ? "true" : "false");
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    });
  }
  tabs.forEach(function (tab, i) {
    tab.addEventListener("click", function () { selectTab(tab); });
    tab.addEventListener("keydown", function (e) {
      var next = null;
      if (e.key === "ArrowRight") next = tabs[(i + 1) % tabs.length];
      if (e.key === "ArrowLeft") next = tabs[(i - 1 + tabs.length) % tabs.length];
      if (next) { e.preventDefault(); selectTab(next); next.focus(); }
    });
  });

  // --- Pre-order form ---------------------------------------------------------
  var form = document.getElementById("orderForm");
  var thanks = document.getElementById("thanks");
  var error = document.getElementById("formError");
  var email = document.getElementById("email");
  var EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var value = email.value.trim();
    if (!EMAIL_RE.test(value)) {
      error.hidden = false;
      email.setAttribute("aria-invalid", "true");
      email.focus();
      return;
    }
    error.hidden = true;
    email.removeAttribute("aria-invalid");

    var region = form.region.value;
    var link = STRIPE_LINKS[region];
    if (link) {
      // Live mode: hand off to Stripe's hosted checkout.
      var url = new URL(link);
      url.searchParams.set("prefilled_email", value);
      if (utm) url.searchParams.set("client_reference_id", utm);
      window.location.href = url.toString();
      return;
    }

    // Demo mode: store nothing, send nothing, just say thanks.
    form.hidden = true;
    thanks.hidden = false;
    thanks.focus();
  });

  document.getElementById("resetForm").addEventListener("click", function () {
    thanks.hidden = true;
    form.hidden = false;
    email.focus();
  });
})();
