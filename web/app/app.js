// Duo Dash website. No dependencies, no tracking, no cookies.
// A small scroll helper drives the scenes (transform/opacity only, one rAF per frame);
// IntersectionObserver handles reveals, the pinned feature story and the film.
// With prefers-reduced-motion, every scene is shown in its finished state.
(function () {
  "use strict";

  var root = document.documentElement;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  var motion = !reduce.matches && "IntersectionObserver" in window;
  if (motion) root.classList.add("motion");

  var clamp = function (v, a, b) { return Math.min(b, Math.max(a, v)); };
  var range = function (p, a, b) { return clamp((p - a) / (b - a), 0, 1); };
  var easeInOut = function (t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; };
  var easeOut = function (t) { return 1 - Math.pow(1 - t, 3); };
  var backOut = function (t) { var c = 1.9; return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2); };

  // ---------------------------------------------------------------------------
  // Scroll helper: scenes register an update(progress) and run only while on screen.
  var scenes = [];
  var vh = window.innerHeight;
  var ticking = false;

  function sceneProgress(el) {
    var r = el.getBoundingClientRect();
    var travel = r.height - vh;
    return travel > 0 ? clamp(-r.top / travel, 0, 1) : (r.top < 0 ? 1 : 0);
  }
  function frame() {
    ticking = false;
    for (var i = 0; i < scenes.length; i++) {
      var s = scenes[i];
      if (s.visible) s.update(sceneProgress(s.el), s.el);
    }
  }
  function requestFrame() {
    if (!ticking) { ticking = true; window.requestAnimationFrame(frame); }
  }
  function addScene(el, update, layout) {
    var s = { el: el, update: update, layout: layout, visible: true };
    scenes.push(s);
    if (layout) layout();
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { s.visible = e.isIntersecting; });
      requestFrame();
    }).observe(el);
  }
  if (motion) {
    window.addEventListener("scroll", requestFrame, { passive: true });
    window.addEventListener("resize", function () {
      vh = window.innerHeight;
      scenes.forEach(function (s) { if (s.layout) s.layout(); });
      requestFrame();
    });
  }

  // ---------------------------------------------------------------------------
  // Hero: the folded phone (cover screen showing) opens like a book toward you.
  // Drawn on a <canvas> (no CSS 3D): the right half is flat; the left half is drawn as
  // vertical strips, each with its own perspective scale, so it swings out toward the
  // viewer. Past 90 degrees the outside of that half (the cover screen) shows instead.
  // Images are the flattened bezel composites (scripts/web-device-images.py).
  var hero = document.querySelector('[data-scene="hero"]');
  if (hero && motion) {
    var copy = hero.querySelector("[data-hero-copy]");
    var fold = hero.querySelector("[data-fold]");
    var canvas = hero.querySelector("[data-fold-canvas]");
    var caption = hero.querySelector("[data-hero-caption]");
    var ctx = canvas && canvas.getContext ? canvas.getContext("2d") : null;
    var startY = 0, startScale = 1, endY = 0, endScale = 1, foldW = 0, foldH = 0;
    var lastOpen = -1, ready = false;
    var big = (Math.min(window.innerWidth, 1100) * (window.devicePixelRatio || 1)) > 1200;
    var imgs = { left: new Image(), right: new Image(), cover: new Image() };
    var pending = 3;

    // Artwork units (the bezel images): open phone 3093 x 2247, hinge at 1546.5;
    // each half image is 1547 wide (the right one starts at 1546); cover 1574 x 2194.
    var UW = 3093, UH = 2247, HINGE = 1546.5, HALF = 1547, CW = 1574, CH = 2194;
    var MARGIN = 0.15; // canvas overhang on each side, as a fraction of the phone size

    var draw = function (open) {
      if (!ready || !ctx) return;
      lastOpen = open;
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      var cw = canvas.width, ch = canvas.height;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, cw, ch);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      var W = foldW, H = foldH, u = W / UW;
      var ox = W * MARGIN, oy = H * MARGIN;          // phone's top-left inside the canvas
      var hinge = ox + HINGE * u, cy = oy + H / 2, L = HINGE * u;
      var phi = (1 - clamp(open, 0, 1)) * Math.PI;   // 0 flat ... pi closed
      var cosP = Math.cos(phi), sinP = Math.sin(phi);
      var F = W * 2.6;                               // camera distance
      var persp = function (d) { return F / (F - d * sinP); };
      var X = function (d) { return hinge - d * cosP * persp(d); };

      // Right half: flat. Hidden while the phone is (nearly) closed, since the cover in
      // front of it is a little shorter than the inner half.
      var ra = range(open, 0.02, 0.12);
      if (ra > 0) {
        ctx.globalAlpha = ra;
        ctx.drawImage(imgs.right, ox + 1546 * u, oy, HALF * u, H);
        ctx.globalAlpha = 1;
      }

      // Left half, in strips. Front (inner screen) while cos > 0, else the cover.
      var front = cosP >= 0;
      var src = front ? imgs.left : imgs.cover;
      var sw = src.naturalWidth, sh = src.naturalHeight;
      var span = front ? L : CW * u;                 // distance from the hinge to the outer edge
      var faceH = front ? H : CH * u;
      var n = 64;
      for (var k = 0; k < n; k++) {
        var d0 = span * k / n, d1 = span * (k + 1) / n;
        var x0 = X(d0), x1 = X(d1);
        var sm = persp((d0 + d1) / 2);
        var hgt = faceH * sm;
        var sx, sWidth = (d1 - d0) / (front ? HALF * u : CW * u) * sw;
        if (front) {
          // Inner face: flat x = hinge - d, i.e. image x from the hinge leftwards.
          sx = (L - d1) / (HALF * u) * sw;           // left image starts at x 0
          ctx.drawImage(src, sx, 0, sWidth, sh, Math.min(x0, x1) - 0.35, cy - hgt / 2, Math.abs(x0 - x1) + 0.7, hgt);
        } else {
          // Cover: its hinge-side edge sits at the hinge, image x = d.
          sx = d0 / (CW * u) * sw;
          ctx.drawImage(src, sx, 0, sWidth, sh, Math.min(x0, x1) - 0.35, cy - hgt / 2, Math.abs(x1 - x0) + 0.7, hgt);
        }
      }

      // Turning away from the light: one shade over the whole swinging half.
      var shade = 0.82 * (1 - Math.abs(cosP));
      if (shade > 0.01) {
        var far = X(span), pf = persp(span), hh = faceH / 2;
        ctx.beginPath();
        ctx.moveTo(hinge, cy - hh); ctx.lineTo(far, cy - hh * pf);
        ctx.lineTo(far, cy + hh * pf); ctx.lineTo(hinge, cy + hh);
        ctx.closePath();
        ctx.fillStyle = "rgba(0,0,0," + shade.toFixed(3) + ")";
        ctx.fill();
      }
    };

    var sizeCanvas = function () {
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      var w = Math.round(foldW * (1 + 2 * MARGIN) * dpr), h = Math.round(foldH * (1 + 2 * MARGIN) * dpr);
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    };

    var loaded = function () {
      if (--pending > 0) return;
      ready = true;
      fold.classList.add("ready");
      sizeCanvas();
      requestFrame();
    };
    var failed = function () { pending = -99; }; // keep the static image
    Object.keys(imgs).forEach(function (key) {
      imgs[key].onload = loaded;
      imgs[key].onerror = failed;
      imgs[key].decoding = "async";
    });
    imgs.left.src = "/assets/duo-fold-left-" + (big ? "2200" : "1100") + ".webp";
    imgs.right.src = "/assets/duo-fold-right-" + (big ? "2200" : "1100") + ".webp";
    imgs.cover.src = "/assets/duo-cover-" + (big ? "1120" : "560") + ".webp";

    var heroLayout = function () {
      fold.style.transform = "none";
      foldW = fold.offsetWidth;
      foldH = fold.offsetHeight;
      var h = foldH;
      var copyBottom = copy.offsetTop + copy.offsetHeight; // untransformed, inside the sticky box
      var room = vh - copyBottom - 28;
      // Start: folded, under the headline (cut off by the bottom edge if it has to be).
      startScale = clamp(room / h, 0.55, 0.92);
      var foldedTop = copyBottom + 20;
      startY = foldedTop + (h * startScale) / 2 - vh / 2;
      // End: open, centred in the space left above the caption.
      var capH = caption.offsetHeight + 40;
      endScale = clamp((vh - 72 - capH - 24) / h, 0.5, 1);
      endY = (72 - capH) / 2 + 6;
      if (ready) { sizeCanvas(); lastOpen = -1; }
    };

    addScene(hero, function (p) {
      var c = range(p, 0, 0.22);
      copy.style.opacity = String(1 - c);
      copy.style.transform = "translate3d(0," + (-60 * c) + "px,0) scale(" + (1 - 0.06 * c) + ")";
      copy.style.visibility = c >= 1 ? "hidden" : "visible";

      var m = easeInOut(range(p, 0.04, 0.62));
      var u = ready ? easeInOut(range(p, 0.14, 0.66)) : 1;
      var y = startY + (endY - startY) * m;
      var s = startScale + (endScale - startScale) * m;
      // Closed, the cover (from the hinge, 1574 of 3093 units wide) is centred: shift left.
      var tx = -(CW / 2 / UW) * foldW * s * (1 - u);
      fold.style.transform = "translate(" + tx.toFixed(1) + "px," + y.toFixed(1) + "px) scale(" + s.toFixed(4) + ")";
      if (Math.abs(u - lastOpen) > 0.0005) draw(u);

      var k = easeOut(range(p, 0.7, 0.86));
      caption.style.opacity = String(k);
      caption.style.transform = "translate3d(0," + (24 * (1 - k)) + "px,0)";
    }, heroLayout);
  }

  // ---------------------------------------------------------------------------
  // Mount page: the problem (open phone tips anticlockwise) and the fix (level).
  var pf = document.querySelector('[data-scene="problem-fix"]');
  if (pf && motion) {
    var probImg = pf.querySelector("[data-pf-problem] img");
    var probFig = pf.querySelector("[data-pf-problem]");
    var fixFig = pf.querySelector("[data-pf-fixed]");
    var fixImg = fixFig.querySelector("img");
    var level = pf.querySelector("[data-pf-level]");
    var msgs = pf.querySelectorAll("[data-pf-msg]");
    var current = -1;
    // The render is tilted 24 degrees; rotating it back +24 shows it level first.
    addScene(pf, function (p) {
      var sag = easeInOut(range(p, 0.1, 0.42));
      probImg.style.transform = "rotate(" + (24 * (1 - sag)) + "deg)";
      var swap = range(p, 0.52, 0.6);
      probFig.style.opacity = String(1 - swap);
      fixFig.style.opacity = String(swap);
      var snap = backOut(range(p, 0.52, 0.68));
      fixImg.style.transform = "translate3d(0," + (30 * (1 - snap)) + "px,0) rotate(" + (-6 * (1 - snap)) + "deg)";
      level.style.opacity = String(range(p, 0.66, 0.74) * (1 - range(p, 0.9, 0.98)) * 0.9 + 0.5 * range(p, 0.02, 0.08) * (1 - range(p, 0.14, 0.2)));
      var idx = p < 0.12 ? 0 : p < 0.5 ? 1 : 2;
      if (idx !== current) {
        current = idx;
        for (var i = 0; i < msgs.length; i++) msgs[i].classList.toggle("on", i === idx);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Parallax (small, transform only).
  if (motion) {
    Array.prototype.forEach.call(document.querySelectorAll("[data-parallax]"), function (el) {
      var speed = parseFloat(el.getAttribute("data-parallax")) || 0;
      var host = el.parentElement;
      addScene(host, function () {
        var r = host.getBoundingClientRect();
        var off = (r.top + r.height / 2 - vh / 2) * speed;
        el.style.transform = "translate3d(0," + off.toFixed(1) + "px,0)";
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Reveal on scroll, and the story lines lighting up.
  if (motion) {
    var revealer = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); revealer.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
    Array.prototype.forEach.call(document.querySelectorAll(".reveal, .reveal-scale"), function (el) { revealer.observe(el); });

    var lighter = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { e.target.classList.toggle("lit", e.isIntersecting); });
    }, { rootMargin: "-38% 0px -38% 0px" });
    Array.prototype.forEach.call(document.querySelectorAll("[data-light]"), function (el) { lighter.observe(el); });
  }

  // ---------------------------------------------------------------------------
  // Pinned feature story: the screen in the frame follows the caption in view.
  var pin = document.querySelector("[data-pin]");
  if (pin) {
    var shots = pin.querySelectorAll(".stack img");
    var dots = pin.querySelectorAll(".pin-dots li");
    var label = pin.querySelector("[data-pin-label]");
    var steps = pin.querySelectorAll("[data-step]");
    var show = function (n) {
      for (var i = 0; i < shots.length; i++) {
        shots[i].classList.toggle("on", i === n);
        if (dots[i]) dots[i].classList.toggle("on", i === n);
        steps[i].classList.toggle("active", i === n);
      }
      if (label) label.textContent = steps[n].getAttribute("data-label");
    };
    // Load all four screens once the section is near, so swaps never flash.
    new IntersectionObserver(function (entries, obs) {
      if (entries[0].isIntersecting) {
        Array.prototype.forEach.call(shots, function (img) { img.loading = "eager"; });
        obs.disconnect();
      }
    }, { rootMargin: "100% 0px" }).observe(pin);
    if ("IntersectionObserver" in window) {
      var stepper = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) show(parseInt(e.target.getAttribute("data-step"), 10));
        });
      }, { rootMargin: window.matchMedia("(max-width: 860px)").matches ? "-62% 0px -34% 0px" : "-45% 0px -45% 0px" });
      Array.prototype.forEach.call(steps, function (s) { stepper.observe(s); });
    }
  }

  // ---------------------------------------------------------------------------
  // The film: plays muted while in view (unless reduced motion), with play and sound buttons.
  var video = document.querySelector("[data-film]");
  if (video) {
    var playBtn = document.querySelector("[data-film-play]");
    var soundBtn = document.querySelector("[data-film-sound]");
    var userPaused = false;
    var inView = false;
    var sync = function () {
      var playing = !video.paused;
      playBtn.querySelector("[data-icon-play]").hidden = playing;
      playBtn.querySelector("[data-icon-pause]").hidden = !playing;
      playBtn.setAttribute("aria-label", playing ? "Pause the film" : "Play the film");
      soundBtn.querySelector("[data-icon-muted]").hidden = !video.muted;
      soundBtn.querySelector("[data-icon-sound]").hidden = video.muted;
      soundBtn.setAttribute("aria-label", video.muted ? "Turn sound on" : "Turn sound off");
    };
    var tryPlay = function () { var r = video.play(); if (r && r.catch) r.catch(function () {}); };
    ["play", "pause", "volumechange"].forEach(function (ev) { video.addEventListener(ev, sync); });
    playBtn.addEventListener("click", function () {
      if (video.paused) { userPaused = false; tryPlay(); } else { userPaused = true; video.pause(); }
    });
    soundBtn.addEventListener("click", function () { video.muted = !video.muted; if (video.paused) tryPlay(); });
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        inView = entries[0].isIntersecting;
        if (inView && motion && !userPaused) tryPlay();
        if (!inView && !video.paused) video.pause();
      }, { threshold: 0.5 }).observe(video);
    }
    // "Watch the film": scroll there and play from the start with sound.
    Array.prototype.forEach.call(document.querySelectorAll("[data-play-film]"), function (a) {
      a.addEventListener("click", function () {
        userPaused = false;
        video.muted = false;
        video.currentTime = 0;
        tryPlay();
      });
    });
    sync();
  }

  // ---------------------------------------------------------------------------
  // Register-your-interest forms (landing teaser and /mount). POST /api/interest stores
  // the email in Cloudflare D1 (functions/api/interest.js). Campaign tags from the link
  // (?utm_source=...) are sent along so we know which link brought people.
  var params = new URLSearchParams(window.location.search);
  var utm = ["utm_source", "utm_medium", "utm_campaign"]
    .map(function (k) { return (params.get(k) || "").replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 40); })
    .filter(Boolean)
    .join("__");
  var EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

  Array.prototype.forEach.call(document.querySelectorAll("[data-interest]"), function (form) {
    var thanks = form.parentElement.querySelector("[data-thanks]");
    var error = form.querySelector("[data-error]");
    var email = form.querySelector('input[type="email"]');
    var button = form.querySelector("[data-submit]");
    var reset = thanks && thanks.querySelector("[data-reset]");

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var value = email.value.trim();
      if (!EMAIL_RE.test(value)) {
        error.textContent = "Please enter a valid email address.";
        error.hidden = false;
        email.setAttribute("aria-invalid", "true");
        email.focus();
        return;
      }
      error.hidden = true;
      email.removeAttribute("aria-invalid");
      button.disabled = true;
      fetch("/api/interest", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: value, region: form.region.value, source: utm, website: form.website.value })
      }).then(function (r) {
        if (!r.ok) throw new Error("status " + r.status);
        form.hidden = true;
        thanks.hidden = false;
        thanks.focus();
      }).catch(function () {
        error.textContent = "That didn't go through. Check your connection and try again.";
        error.hidden = false;
      }).then(function () { button.disabled = false; });
    });

    // Back from a plain (no-JavaScript) form post.
    if (params.get("registered") === "1" && thanks) { form.hidden = true; thanks.hidden = false; }
    if (reset) reset.addEventListener("click", function () { thanks.hidden = true; form.hidden = false; email.focus(); });
  });
})();
