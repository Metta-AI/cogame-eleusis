// Eleusis shared renderer + drivers.
//
// One canvas scene — the laboratory bench. Token strips feed a sealed
// black-box machine on the left that stamps PASS or FAIL; published results
// pin to the shared corkboard on the right; hoarded ones slide into the
// filing drawer at the bottom-left that only spectators can see. The
// prediction-test panel and the drawer's card are HTML over the canvas (they
// stay crisp at 360px); everything else is drawn.
//
// The chrome half of this file — the two name spaces, the feed, the
// scorebug, the endscreen, the scrubber, the drivers, the effects
// bookkeeping and the text helpers — is cogame-bullwhip's client/renderer.js
// kept as-is; only the board-drawing half and describeEvent are this game's.
//
// Fed by two drivers: the live /global websocket and a replay (from the
// game's /replay websocket or the static wasm bundle). All state derivation
// happens server-side / wasm-side; this file only draws state objects:
//   {seats:[{name,score,knowledge,credit,spend,experiments,published,
//            hoarded,correct,answered,hypothesis,notes,pending,
//            last:{strip,verdict,mode}|null,
//            secrets:[{strip,verdict,round}]} x5 by SEAT],
//    board:[{strip,verdict,author,round,cites,duplicate}],
//    machine:{seat,round,strip,verdict}|null,
//    test:{index,round,strips,truth,answers,correct,open}|null,
//    citations:[{author,by,strip,amount,test}],
//    round,rounds,testEvery,testStrips,testsDone,decided,phase,rule,ruleId,
//    closest,gameDone,reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Seats are
  // red, blue, green, yellow, violet — the fifth seat is why data/ carries a
  // violet cog.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  // A token is a colour AND its letter, so the bench reads in greyscale.
  var TOKEN_HEX = {
    R: "#e0523a",
    B: "#3f7cc4",
    G: "#45a85e",
    Y: "#ddc531"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var PASS_HEX = "#45a85e";
  var FAIL_HEX = "#e0523a";
  var CORK = "#8a6a3c";
  var CORK_EDGE = "#4c3a20";
  var HOUSING = "#2b211a";
  var STRIP_BG = "rgba(242, 232, 216, 0.06)";
  // Timing of the bench beats: the strip feeds in, the stamp drops, the
  // drawer slides open and shuts again.
  var FEED_MS = 500;
  var STAMP_MS = 900;
  var DRAWER_MS = 2600;
  var PUBLISH_MS = 1400;
  var MAX_CARDS = 24;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["cog_red_front.png", "cog_blue_front.png",
      "cog_green_front.png", "cog_yellow_front.png", "cog_violet_front.png",
      "bench_surface.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function money(value) {
    var v = Math.round((value || 0) * 10) / 10;
    return (v < 0 ? "-$" : "$") + Math.abs(v).toFixed(1);
  }

  function verdictWord(verdict) {
    // Words, never P/F: a casual spectator has to be able to read it.
    return String(verdict || "").toLowerCase() === "pass" ? "PASS" : "FAIL";
  }

  function verdictHex(verdict) {
    return String(verdict || "").toLowerCase() === "pass" ? PASS_HEX : FAIL_HEX;
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Layout --------------------------------------------------------------

  // The bench is a fixed composition — there is never anything larger than
  // the frame, so there is no zoom bar and no minimap. Two columns: the
  // machine (with the crew under it and the filing cabinet at its foot) and
  // the corkboard down the right-hand side.
  function computeLayout(width, height) {
    var margin = 10;
    var boardW = Math.max(132, Math.min(width * 0.34, 330));
    var benchX = margin;
    var benchW = Math.max(120, width - boardW - margin * 2 - 8);
    var scale = Math.max(0.62, Math.min(1.35, width / 960));
    var machineH = Math.max(96, Math.min(height * 0.46, 260));
    var machineW = Math.min(benchW * 0.82, 420 * scale);
    var machineX = benchX + (benchW - machineW) / 2;
    var machineY = margin + Math.max(8, height * 0.06);
    var crewY = machineY + machineH + Math.max(24, 34 * scale);
    var cabinetH = Math.max(40, 54 * scale);
    return {
      width: width, height: height, margin: margin, scale: scale,
      bench: { x: benchX, y: margin, w: benchW, h: height - margin * 2 },
      machine: { x: machineX, y: machineY, w: machineW, h: machineH },
      crew: { x: benchX, y: crewY, w: benchW,
        h: Math.max(30, height - crewY - cabinetH - margin) },
      cabinet: { x: benchX + 2, y: height - margin - cabinetH,
        w: Math.min(benchW - 4, 260 * scale), h: cabinetH },
      board: { x: width - boardW - margin, y: margin, w: boardW,
        h: height - margin * 2 }
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    if (!w || !h) return;
    var L = computeLayout(w, h);
    var now = view.now || Date.now();
    var fx = view.effects || {};

    // Worktop.
    var bench = images["bench_surface.png"];
    if (bench && bench.width) {
      ctx.fillStyle = ctx.createPattern(bench, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.42)";
    ctx.fillRect(0, 0, w, h);

    ctx.save();
    ctx.fillStyle = STRIP_BG;
    roundRect(ctx, L.bench.x - 4, L.bench.y, L.bench.w + 8, L.bench.h,
      10 * L.scale);
    ctx.fill();
    ctx.restore();

    drawMachine(ctx, L, view, fx, now);
    drawCrew(ctx, images, L, view, fx, now);
    drawCabinet(ctx, L, view, fx, now);
    drawCorkboard(ctx, L, view, fx, now);
  }

  // A strip of four coloured tokens, each carrying its letter.
  function drawStrip(ctx, x, y, size, strip, alpha) {
    var text = String(strip || "");
    ctx.save();
    if (typeof alpha === "number") ctx.globalAlpha = alpha;
    for (var i = 0; i < text.length; i++) {
      var letter = text.charAt(i);
      var tx = x + i * (size + Math.max(1, size * 0.12));
      ctx.fillStyle = TOKEN_HEX[letter] || PAPER_DIM;
      ctx.fillRect(tx, y, size, size);
      ctx.strokeStyle = "rgba(18, 13, 9, 0.65)";
      ctx.lineWidth = 1;
      ctx.strokeRect(tx + 0.5, y + 0.5, size - 1, size - 1);
      ctx.fillStyle = INK;
      ctx.font = "700 " + Math.round(size * 0.72) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(letter, tx + size / 2, y + size / 2 + size * 0.04);
    }
    ctx.restore();
  }

  function stripWidth(size, length) {
    var n = length || 4;
    return n * size + (n - 1) * Math.max(1, size * 0.12);
  }

  // The sealed machine: a squat housing with an intake slot on the left. The
  // strip under test slides in, then the rubber stamp drops.
  function drawMachine(ctx, L, view, fx, now) {
    var m = L.machine;
    var scale = L.scale;
    var machine = view.machine || null;
    var age = typeof fx.machineAt === "number" ? now - fx.machineAt : 99999;

    ctx.save();
    // Housing.
    ctx.fillStyle = HOUSING;
    roundRect(ctx, m.x, m.y, m.w, m.h, 10 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 2;
    ctx.stroke();
    // Rivets.
    ctx.fillStyle = "rgba(242, 232, 216, 0.16)";
    for (var i = 0; i < 4; i++) {
      var rx = m.x + 9 * scale + (m.w - 18 * scale) * (i / 3);
      ctx.beginPath();
      ctx.arc(rx, m.y + 9 * scale, 2.4 * scale, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(rx, m.y + m.h - 9 * scale, 2.4 * scale, 0, Math.PI * 2);
      ctx.fill();
    }
    // Plate.
    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.fillText("THE MACHINE", m.x + m.w / 2, m.y + 8 * scale);
    ctx.font = "600 " + Math.round(8.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = GHOST;
    ctx.fillText("ONE HIDDEN RULE", m.x + m.w / 2, m.y + 21 * scale);

    // Intake slot on the left flank.
    var slotH = Math.max(16, 26 * scale);
    var slotY = m.y + m.h * 0.52 - slotH / 2;
    ctx.fillStyle = "#0f0b07";
    roundRect(ctx, m.x - 5 * scale, slotY, 16 * scale, slotH, 3 * scale);
    ctx.fill();

    // The strip being stamped.
    var tokenSize = Math.max(16, Math.min(34 * scale, m.w / 6));
    var sw = stripWidth(tokenSize, 4);
    var restX = m.x + m.w / 2 - sw / 2;
    var trayY = m.y + m.h * 0.52 - tokenSize / 2;
    // Feed tray.
    ctx.fillStyle = "rgba(12, 8, 5, 0.55)";
    roundRect(ctx, m.x + 12 * scale, trayY - 7 * scale, m.w - 24 * scale,
      tokenSize + 14 * scale, 4 * scale);
    ctx.fill();

    if (machine && machine.strip) {
      var feed = Math.min(1, age / FEED_MS);
      var eased = 1 - Math.pow(1 - feed, 3);
      var fromX = m.x - sw - 6 * scale;
      drawStrip(ctx, fromX + (restX - fromX) * eased, trayY, tokenSize,
        machine.strip);
      if (age > FEED_MS) {
        drawStamp(ctx, m.x + m.w / 2, m.y + m.h * 0.82, scale,
          machine.verdict, machine.seat, Math.min(1, (age - FEED_MS) / 260));
      }
      ctx.font = "600 " + Math.round(9.5 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = GHOST;
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.fillText("PRIVATE TO THE SEAT THAT PAID FOR IT",
        m.x + m.w / 2, m.y + m.h - 15 * scale);
    } else {
      ctx.font = "600 " + Math.round(11 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = rgba(PAPER, 0.35);
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("FEED ME A STRIP", m.x + m.w / 2, trayY + tokenSize / 2);
    }
    ctx.restore();
  }

  // A rubber stamp: the word, in green or red, on the author's seat rim.
  function drawStamp(ctx, cx, cy, scale, verdict, seat, drop) {
    var word = verdictWord(verdict);
    var color = verdictHex(verdict);
    var rim = COLOR_HEX[seatColor(seat || 0)];
    var w = Math.max(74, 108 * scale);
    var h = Math.max(28, 40 * scale);
    var lift = (1 - drop) * 22 * scale;
    ctx.save();
    ctx.globalAlpha = 0.35 + 0.65 * drop;
    ctx.translate(cx, cy - lift);
    ctx.rotate(-0.06);
    ctx.fillStyle = "rgba(242, 232, 216, 0.94)";
    roundRect(ctx, -w / 2, -h / 2, w, h, 4 * scale);
    ctx.fill();
    ctx.strokeStyle = rim;
    ctx.lineWidth = 3;
    ctx.stroke();
    ctx.fillStyle = color;
    ctx.font = "700 " + Math.round(h * 0.62) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(word, 0, h * 0.04);
    ctx.restore();
  }

  // The five cogs at the bench, in seat colours, with their public
  // hypothesis line under them.
  function drawCrew(ctx, images, L, view, fx, now) {
    var seats = view.seats || [];
    if (!seats.length) return;
    var scale = L.scale;
    var pitch = L.crew.w / seats.length;
    var size = Math.max(26, Math.min(72 * scale, pitch * 0.44, L.crew.h * 0.62));
    var machine = view.machine || null;
    for (var i = 0; i < seats.length; i++) {
      var seat = seats[i] || {};
      var cx = L.crew.x + pitch * (i + 0.5);
      var cy = L.crew.y + size / 2;
      var color = seatColor(i);
      var sprite = images["cog_" + color + "_front.png"];
      ctx.save();
      if (machine && machine.seat === i) {
        ctx.shadowColor = COLOR_HEX[color];
        ctx.shadowBlur = 16;
      }
      if (sprite && sprite.width) {
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(sprite, cx - size / 2, cy - size / 2, size, size);
      } else {
        ctx.fillStyle = COLOR_HEX[color];
        ctx.fillRect(cx - size / 3, cy - size / 3, size / 1.5, size / 1.5);
      }
      ctx.restore();

      // Holding an undisclosed result: a dashed halo, the tell that a
      // decision is coming.
      if (seat.pending) {
        ctx.save();
        ctx.strokeStyle = AMBER;
        ctx.lineWidth = 2;
        ctx.setLineDash([5, 4]);
        ctx.beginPath();
        ctx.arc(cx, cy, size * 0.58, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      ctx.save();
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.font = "600 " + Math.round(11 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      ctx.fillText(ellipsize(ctx, seat.name || "", pitch * 0.94), cx,
        cy + size * 0.55);
      ctx.font = "700 " + Math.round(12 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = AMBER;
      ctx.fillText(money(seat.score), cx, cy + size * 0.55 + 13 * scale);
      if (seat.hypothesis) {
        ctx.font = Math.round(9.5 * scale) +
          "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
        ctx.fillStyle = rgba(COLOR_HEX[color], 0.95);
        ctx.fillText(ellipsize(ctx, "“" + seat.hypothesis + "”",
          pitch * 0.96), cx, cy + size * 0.55 + 27 * scale);
      }
      ctx.restore();
    }
  }

  // The filing cabinet at the foot of the bench. It slides open on a hoard
  // beat; the card itself is the HTML #drawer over the top of it, so the
  // SECRET tag stays crisp at 360px.
  function drawCabinet(ctx, L, view, fx, now) {
    var c = L.cabinet;
    var scale = L.scale;
    var age = typeof fx.hoardAt === "number" ? now - fx.hoardAt : 99999;
    var open = age < DRAWER_MS ? Math.min(1, age / 260) : 0;
    if (age >= DRAWER_MS && age < DRAWER_MS + 400) {
      open = 1 - (age - DRAWER_MS) / 400;
    }
    ctx.save();
    ctx.fillStyle = "rgba(20, 14, 10, 0.92)";
    roundRect(ctx, c.x, c.y, c.w, c.h, 4 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = 1;
    ctx.stroke();
    // The drawer front, pulled out by `open`.
    var pull = 10 * scale * open;
    ctx.fillStyle = open > 0 ? "rgba(168, 111, 214, 0.22)" :
      "rgba(242, 232, 216, 0.05)";
    roundRect(ctx, c.x + 4, c.y + 6 + pull, c.w - 8, c.h - 12, 3 * scale);
    ctx.fill();
    ctx.strokeStyle = open > 0 ? COLOR_HEX.violet : "rgba(242,232,216,0.18)";
    ctx.setLineDash([5, 4]);
    ctx.stroke();
    ctx.setLineDash([]);
    // Handle.
    ctx.fillStyle = "rgba(242, 232, 216, 0.3)";
    ctx.fillRect(c.x + c.w / 2 - 14 * scale, c.y + c.h / 2 + pull - 2,
      28 * scale, 4);
    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = open > 0 ? COLOR_HEX.violet : GHOST;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    var secrets = 0;
    (view.seats || []).forEach(function (seat) {
      secrets += (seat && seat.secrets ? seat.secrets.length : 0);
    });
    ctx.fillText("HOARDED RESULTS · " + secrets, c.x + 8, c.y + 5);
    ctx.restore();
  }

  // The corkboard: published facts as pinned index cards, newest first.
  function drawCorkboard(ctx, L, view, fx, now) {
    var b = L.board;
    var scale = L.scale;
    var board = (view.board || []).slice();
    ctx.save();
    ctx.fillStyle = CORK;
    roundRect(ctx, b.x, b.y, b.w, b.h, 6 * scale);
    ctx.fill();
    ctx.fillStyle = "rgba(42, 31, 22, 0.35)";
    roundRect(ctx, b.x, b.y, b.w, b.h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = CORK_EDGE;
    ctx.lineWidth = 2;
    ctx.stroke();

    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.fillText("THE CORKBOARD", b.x + b.w / 2, b.y + 6 * scale);
    ctx.font = "600 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = "rgba(242, 232, 216, 0.7)";
    ctx.fillText(board.length + " PUBLISHED", b.x + b.w / 2, b.y + 19 * scale);

    var top = b.y + 32 * scale;
    var cardH = Math.max(30, 40 * scale);
    var gap = 5 * scale;
    // Narrow frames show fewer cards; the newest are the ones that matter.
    var room = Math.max(1, Math.floor((b.y + b.h - top - 4) / (cardH + gap)));
    var limit = Math.min(MAX_CARDS, room, b.w < 150 ? 8 : MAX_CARDS);
    var newest = board.slice(-limit).reverse();
    var hidden = board.length - newest.length;
    for (var i = 0; i < newest.length; i++) {
      var y = top + i * (cardH + gap);
      if (hidden > 0 && i === newest.length - 1) {
        ctx.font = "600 " + Math.round(10 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.fillStyle = "rgba(242, 232, 216, 0.75)";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText("+" + hidden + " earlier", b.x + b.w / 2, y + cardH / 2);
        break;
      }
      drawCard(ctx, b.x + 6 * scale, y, b.w - 12 * scale, cardH, scale,
        newest[i], fx, now);
    }
    ctx.restore();
  }

  function drawCard(ctx, x, y, w, h, scale, fact, fx, now) {
    var fresh = typeof fx.publishAt === "number" &&
      fx.lastPublish === fact.strip && now - fx.publishAt < PUBLISH_MS;
    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.45)";
    ctx.shadowBlur = 4;
    ctx.fillStyle = fresh ? "#fffaf0" : PAPER;
    roundRect(ctx, x, y, w, h, 2);
    ctx.fill();
    ctx.shadowColor = "transparent";
    if (fresh) {
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 2;
      ctx.stroke();
    }
    var token = Math.max(10, Math.min(18 * scale, (w - 66 * scale) / 4.6));
    drawStrip(ctx, x + 6 * scale, y + (h - token) / 2, token, fact.strip);
    var textX = x + 6 * scale + stripWidth(token, 4) + 6 * scale;
    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = verdictHex(fact.verdict);
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillText(verdictWord(fact.verdict), textX, y + h * 0.42);
    ctx.font = "600 " + Math.round(8.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = "#6b5a45";
    ctx.fillText("r" + fact.round +
      (fact.cites ? "  +" + money(fact.cites) : ""), textX, y + h * 0.76);
    // A pin in the author's seat colour; a duplicate has no pin and carries
    // a CONFIRMED overprint instead.
    if (fact.duplicate || fact.author < 0) {
      ctx.save();
      ctx.translate(x + w * 0.62, y + h / 2);
      ctx.rotate(-0.22);
      ctx.font = "700 " + Math.round(10 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = "rgba(224, 82, 58, 0.55)";
      ctx.textAlign = "center";
      ctx.fillText("CONFIRMED", 0, 0);
      ctx.restore();
    } else {
      ctx.beginPath();
      ctx.arc(x + w - 9 * scale, y + 9 * scale, 4 * scale, 0, Math.PI * 2);
      ctx.fillStyle = COLOR_HEX[seatColor(fact.author)];
      ctx.fill();
      ctx.strokeStyle = "rgba(42, 31, 22, 0.5)";
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous bench aliases ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "The machine is sealed. One rule out of 68, 256 strips, " +
          "five rivals.";
      case "round":
        return "";
      case "experiment":
        return name(event.seat) + " tests " + event.strip + " → " +
          verdictWord(event.verdict) + " (private)" +
          (event.scripted ? " ·" : "");
      case "skip":
        return name(event.seat) + " runs no experiment this round" +
          (event.scripted ? " ·" : "");
      case "disclose":
        if (event.mode === "publish") {
          return name(event.seat) + " pins " + event.strip + " · " +
            verdictWord(event.verdict) + " to the corkboard";
        }
        if (event.mode === "duplicate") {
          return name(event.seat) + " re-publishes " + event.strip +
            " — already on the board, no credit";
        }
        return name(event.seat) + " slides " + event.strip + " · " +
          verdictWord(event.verdict) + " into the drawer";
      case "test":
        return "PREDICTION TEST " + event.test + " — " +
          (event.strips || []).join("  ") + " — nobody has tested these.";
      case "answer":
        return name(event.seat) + " answers " + event.correct + "/" +
          (event.answers || []).length + " correct" +
          (event.scripted ? " ·" : "");
      case "settle":
        var parts = (event.correct || []).map(function (c, i) {
          return name(i) + " " + c;
        });
        return "TEST " + event.test + " SETTLED — " + parts.join(", ");
      case "end":
        return "THE RULE WAS " + (event.rule || "") +
          (event.text === "deadline" ? " — episode deadline." : "");
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block) {
    if (block < 0) return "SETUP";
    return "ROUND " + block;
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = {};
    var lastHypothesis = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        (typeof event.round === "number" ? event.round : lastBlock);
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      var text = describeEvent(event, nameMap, ctx);
      if (!text) continue;
      var seatClass = typeof event.seat === "number" && event.seat >= 0 ?
        " seat" + (event.seat % COLORS.length) : "";
      var cls = "feed-line feed-" + event.kind + seatClass +
        (event.kind === "disclose" && event.mode === "hoard" ?
          " feed-hoard" : "") +
        (event.kind === "disclose" && event.mode !== "hoard" ?
          " feed-publish" : "") +
        (event.kind === "end" ? " feed-rule" : "") +
        (i >= limit ? " feed-future" : "");
      // describeEvent already renders seat names through the map; running
      // the line through nameMap.text() as well would rewrite a display name
      // that happens to be another seat's alias a second time.
      html += '<div class="' + cls + '">' + escapeHtml(text) + "</div>";
      // Citations, in the money colour.
      if (event.kind === "settle") {
        (event.citations || []).forEach(function (cite) {
          html += '<div class="feed-line feed-cite' +
            (i >= limit ? " feed-future" : "") + '">' +
            escapeHtml(clampName(nameMap.seat(cite.author)) + "'s " +
              cite.strip + " cited by " + clampName(nameMap.seat(cite.by)) +
              "  +" + money(cite.amount)) + "</div>";
        });
      }
      // A seat's public hypothesis, in its colour, only when it changed.
      if (event.hypothesis && event.hypothesis !== lastHypothesis[event.seat]) {
        lastHypothesis[event.seat] = event.hypothesis;
        html += '<div class="feed-line feed-hypothesis' + seatClass +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + ": “" +
            nameMap.text(event.hypothesis) + "”") + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the machine last stamped, when the corkboard last took a card, and
  // when the drawer last opened.
  function makeEffects() {
    var seen = 0;
    var machineAt = null;
    var publishAt = null;
    var hoardAt = null;
    var lastPublish = "";
    var lastHoard = null;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "experiment") {
            machineAt = animate ? now : null;
          } else if (event.kind === "disclose") {
            if (event.mode === "hoard") {
              hoardAt = animate ? now : null;
              lastHoard = { seat: event.seat, strip: event.strip,
                verdict: event.verdict };
            } else {
              publishAt = animate ? now : null;
              lastPublish = event.strip;
            }
          }
        }
      },
      reset: function () {
        seen = 0;
        machineAt = null;
        publishAt = null;
        hoardAt = null;
        lastPublish = "";
        lastHoard = null;
      },
      view: function () {
        return { effects: { machineAt: machineAt, publishAt: publishAt,
          hoardAt: hoardAt, lastPublish: lastPublish, lastHoard: lastHoard } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      var total = state.rounds || (config && config.rounds) || 0;
      if (state.phase === "test" && state.test) {
        var tests = total && state.testEvery ?
          Math.ceil(total / state.testEvery) : 0;
        parts.push("PREDICTION TEST " + (state.test.index || 0) +
          (tests ? " / " + tests : ""));
      } else {
        parts.push("ROUND " + (state.round || 0) + (total ? " / " + total : ""));
      }
      if (state.gameDone || state.done) {
        parts.push("FINAL");
      } else if (typeof state.decided === "number") {
        parts.push(state.decided + " OF " + (state.seats || []).length +
          (state.phase === "test" ? " ANSWERED" : " IN"));
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + escapeHtml(money(seat.score)) +
        "</span>" +
        '<span class="plate-chip pub">PUB ' + (seat.published || 0) +
        "</span>" +
        '<span class="plate-chip sec">SEC ' + (seat.hoarded || 0) +
        "</span>" +
        (seat.credit ? '<span class="plate-chip cite">+' +
          escapeHtml(money(seat.credit)) + "</span>" : "") +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // ---- The prediction-test panel and the drawer (HTML over the canvas) ----

  function updateTestPanel(element, state, nameMap) {
    if (!element) return;
    var test = state && state.test;
    if (!test || !test.strips || !test.strips.length) {
      element.classList.remove("show");
      element.dataset.html = "";
      element.innerHTML = "";
      return;
    }
    // A test the deadline closed was never marked: it is not open, but its
    // truth and its pips stay sealed, because nobody was scored on it.
    var settled = !test.open && !test.discarded;
    var html = '<span class="tp-caption">TEST ' + (test.index || 0) +
      (test.discarded ? " · DISCARDED" : "") + "</span>";
    test.strips.forEach(function (strip, i) {
      var tokens = "";
      String(strip).split("").forEach(function (letter) {
        tokens += '<span class="tp-token ' + letter + '" style="--tc:' +
          (TOKEN_HEX[letter] || "#b8ac98") + '">' + escapeHtml(letter) +
          "</span>";
      });
      var pips = "";
      (state.seats || []).forEach(function (seat, s) {
        var row = (test.answers || [])[s];
        var cls = "tp-pip unknown";
        if (settled && row && row[i]) {
          cls = "tp-pip" + (row[i] === (test.truth || [])[i] ? "" : " wrong");
        }
        pips += '<span class="' + cls + '" style="--tc:' +
          COLOR_HEX[seatColor(s)] + '"></span>';
      });
      var truth = settled && test.truth ? test.truth[i] : null;
      html += '<span class="tp-strip"><span class="tp-tokens">' + tokens +
        '</span><span class="tp-truth ' + (truth || "") + '">' +
        (truth ? verdictWord(truth) : "SEALED") + "</span>" +
        '<span class="tp-pips">' + pips + "</span></span>";
    });
    if (element.dataset.html !== html) {
      element.dataset.html = html;
      element.innerHTML = html;
    }
    element.classList.add("show");
  }

  function updateDrawer(element, state, nameMap, effects, now) {
    if (!element) return;
    var fx = (effects && effects.effects) || {};
    var open = typeof fx.hoardAt === "number" && now - fx.hoardAt < DRAWER_MS;
    var secrets = 0;
    (state && state.seats ? state.seats : []).forEach(function (seat) {
      secrets += (seat && seat.secrets ? seat.secrets.length : 0);
    });
    var card = "";
    if (open && fx.lastHoard) {
      card = '<span class="dr-card" style="--tc:' +
        COLOR_HEX[seatColor(fx.lastHoard.seat)] + '">' +
        '<span class="dr-name">' +
        escapeHtml(clampName(nameMap ? nameMap.seat(fx.lastHoard.seat) : "")) +
        "</span>" +
        '<span class="dr-name">' + escapeHtml(fx.lastHoard.strip) + "</span>" +
        '<span class="dr-verdict ' + (fx.lastHoard.verdict || "") + '">' +
        verdictWord(fx.lastHoard.verdict) + "</span></span>";
    }
    var html = '<span class="dr-tag">SECRET · SPECTATORS ONLY · ' + secrets +
      "</span>" + card;
    if (element.dataset.html !== html) {
      element.dataset.html = html;
      element.innerHTML = html;
    }
    element.classList.toggle("show", open || secrets > 0);
  }

  function reasonLine(results, nameMap) {
    var parts = [];
    var closest = typeof results.closest === "number" ? results.closest : -1;
    if (closest >= 0) {
      parts.push("closest: " + clampName(nameMap ? nameMap.seat(closest) :
        results.closestName || "") + " — " +
        ((results.correct || [])[closest] || 0) + " of " +
        ((results.answered || [])[closest] || 0) + " predictions");
    } else {
      parts.push("no test was scored");
    }
    parts.push("ended " + (results.reason || "complete"));
    return parts.join(" · ");
  }

  // Final standings overlay: the rule up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var html = '<div class="end-panel">' +
      '<div class="end-title">THE RULE WAS</div>' +
      '<div class="end-verdict ' + verdictColor + '">' +
      escapeHtml(results.rule || "—") + "</div>" +
      '<div class="end-reason">' + escapeHtml(reasonLine(results, nameMap)) +
      "</div>" +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">prizes</span>' +
      '<span class="end-head">credit</span>' +
      '<span class="end-head">spend</span>' +
      '<span class="end-head">accuracy</span>' +
      '<span class="end-head">pub/sec</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value, extra) {
        return '<span class="end-cell' + (extra ? " " + extra : "") +
          (leader ? " end-row-winner" : "") + '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i] || "") +
        "</span>" +
        cell(escapeHtml(money(scores[i]))) +
        cell(escapeHtml(money((results.knowledge || [])[i]))) +
        cell(escapeHtml(money((results.credit || [])[i]))) +
        cell(escapeHtml(money((results.spend || [])[i]))) +
        cell(((results.correct || [])[i] || 0) + "/" +
          ((results.answered || [])[i] || 0)) +
        cell(((results.published || [])[i] || 0) + "/" +
          ((results.hoarded || [])[i] || 0), "pubsec");
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Layout variables ----------------------------------------------------

  // The ONLY writer of layout variables. --band is the measured height of the
  // transport bar, so nothing (the endcard included) is ever overlaid on the
  // scrubber; --hudscale keeps the HTML overlays readable in a 360px iframe.
  function relayout() {
    var root = document.documentElement;
    var transport = document.getElementById("transport");
    var band = transport ? Math.round(transport.getBoundingClientRect().height) : 0;
    root.style.setProperty("--band", band + "px");
    var stage = document.getElementById("stage");
    var width = stage ? stage.getBoundingClientRect().width :
      (window.innerWidth || 960);
    var hudscale = Math.max(0.75, Math.min(1.25, width / 960));
    root.style.setProperty("--hudscale", String(Math.round(hudscale * 100) / 100));
  }

  function bindRelayout() {
    relayout();
    window.addEventListener("load", relayout);
    window.addEventListener("resize", relayout);
    var stage = document.getElementById("stage");
    if (stage && typeof ResizeObserver === "function") {
      new ResizeObserver(function () { relayout(); }).observe(stage);
    }
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.board = state.board || [];
    view.machine = state.machine || null;
    view.test = state.test || null;
    view.citations = state.citations || [];
    view.round = state.round || 0;
    view.rounds = state.rounds || 0;
    view.testEvery = state.testEvery || 0;
    view.testStrips = state.testStrips || 0;
    view.testsDone = state.testsDone || 0;
    view.phase = state.phase || "";
    view.rule = state.rule || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame ({slot, score, ...}) becomes a five-seat state
  // with the own seat filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var seats = [];
    for (var i = 0; i < 5; i++) {
      seats.push({ name: "Seat " + i, score: 0, secrets: [] });
    }
    if (typeof data.slot === "number") {
      seats[data.slot] = {
        name: data.name,
        score: data.score,
        knowledge: data.knowledge,
        credit: data.credit,
        spend: data.spend,
        experiments: data.experiments,
        published: data.published,
        hoarded: data.hoarded,
        correct: data.correct,
        answered: data.answered,
        pending: !!data.pending,
        hypothesis: "",
        secrets: []
      };
    }
    return {
      seats: seats, board: [], machine: null, test: null, citations: [],
      round: data.round, rounds: data.rounds, phase: data.phase,
      gameDone: data.done, reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen, testpanel,
    //           drawer, assetBase, wsPath, onFrame}
    bindRelayout();
    var testpanel = options.testpanel || document.getElementById("testpanel");
    var drawer = options.drawer || document.getElementById("drawer");
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
              updateTestPanel(testpanel, latest, nameMap);
              updateDrawer(drawer, latest, nameMap, effects.view(),
                Date.now());
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone),
            gameDone: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per round, and one
  // labelled, clickable BUTTON per beat — an experiment (in the seat's
  // colour), a publication, a hoard, a prediction test, the end.
  function beatFor(event, nameMap) {
    function name(i) { return clampName(nameMap.seat(i)); }
    switch (event.kind) {
      case "experiment":
        return { cls: "beat-experiment seat" + (event.seat % COLORS.length),
          label: "round " + event.round + " — " + name(event.seat) +
            " tests " + event.strip };
      case "disclose":
        if (event.mode === "hoard") {
          return { cls: "beat-hoard seat" + (event.seat % COLORS.length),
            label: "round " + event.round + " — " + name(event.seat) +
              " hoards " + event.strip + " (" + verdictWord(event.verdict) +
              ")" };
        }
        return { cls: "beat-publish seat" + (event.seat % COLORS.length),
          label: "round " + event.round + " — " + name(event.seat) +
            " publishes " + event.strip + " (" + verdictWord(event.verdict) +
            ")" };
      case "test":
        return { cls: "beat-test", label: "prediction test " + event.test };
      case "end":
        return { cls: "beat-end death", label: "the rule is revealed" };
      default:
        return null;
    }
  }

  function buildScrub(container, events, nameMap, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        (typeof event.round === "number" ? event.round : lastBlock);
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var beat = beatFor(event, nameMap);
      if (!beat) return;
      var marker = document.createElement("button");
      marker.type = "button";
      marker.className = "beat-marker " + beat.cls;
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      marker.setAttribute("aria-label", beat.label);
      marker.title = beat.label;
      marker.onclick = function (evt) {
        evt.stopPropagation();
        onSeek(i + 1);
      };
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, testpanel, drawer, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var testpanel = options.testpanel || document.getElementById("testpanel");
    var drawer = options.drawer || document.getElementById("drawer");
    var index = 0;
    var playing = true;
    var lastStep = 0;
    bindRelayout();

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, nameMap, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", round: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateTestPanel(testpanel, currentState(), nameMap);
        // Every seek dismisses the endcard: it shows only on the final frame.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is looking at: a test draw and a
        // settlement get read, an experiment gets watched, a skip does not.
        var shown = index > 0 ? events[index - 1] : null;
        var kind = shown ? shown.kind : "";
        var stepMs = kind === "test" ? 1500 :
          kind === "settle" ? 1600 :
          kind === "experiment" ? 700 :
          kind === "disclose" ? 600 :
          kind === "answer" ? 500 :
          kind === "skip" ? 300 :
          kind === "end" ? 1500 :
          650;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var state = currentState();
        var view = stateToView(state, nameMap, effects, {
          done: index >= events.length && events.length > 0,
          gameDone: state.gameDone
        });
        updateDrawer(drawer, state, nameMap, effects.view(), view.now);
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.EleusisRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle,
    relayout: relayout
  };
})();
