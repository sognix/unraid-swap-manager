// history.js — swap usage history graph, shared by the settings page and the dashboard tile.
// Data from exec.php (action=history); drawn in the browser so the hover tooltip works.
// Usage: var g = swapHistory(chartElement, {height: 160, range: 300}); g.range(3600);
// The range (seconds: 300, 3600, 86400) is a setting (cfg history_range), not chosen here.

function swapHuman(kb) {
  if (kb >= 1048576) return (kb / 1048576).toFixed(1) + ' GB';
  if (kb >= 1024) return Math.round(kb / 1024) + ' MB';
  return kb + ' kB';
}

function swapHistory(chart, opts) {
  var box = $(chart), st = {range: opts.range || 300, data: null, mouse: null};
  var H = opts.height || 160, color = '#e6821e';

  function clock(t, sec) {
    var o = {hour: '2-digit', minute: '2-digit'};
    if (sec) o.second = '2-digit';
    return new Date(t * 1000).toLocaleTimeString([], o);
  }

  function geom() {
    var d = st.data, W = Math.max(box.width(), 200);
    var g = {W: W, H: H, L: 60, R: 10, T: 10, B: 22, max: 0};
    g.pw = W - g.L - g.R; g.ph = H - g.T - g.B;
    d.points.forEach(function(p) { g.max = Math.max(g.max, p[1], p[2]); });
    g.x = function(t) { return g.L + (t - (d.now - d.range)) / d.range * g.pw; };
    g.y = function(v) { return g.T + g.ph - (g.max ? v / g.max * g.ph : 0); };
    return g;
  }

  function draw() {
    var d = st.data; if (!d) return;
    var g = geom(), pts = d.points, sec = d.range <= 300;
    var ink = 'fill="var(--text-color)" opacity="0.7" font-size="11"';
    var svg = '<svg width="' + g.W + '" height="' + g.H + '" style="display:block">';
    // recessive grid + y labels (0, half, max)
    [0, 0.5, 1].forEach(function(f) {
      var yy = g.T + g.ph - f * g.ph;
      svg += '<line x1="' + g.L + '" x2="' + (g.W - g.R) + '" y1="' + yy + '" y2="' + yy +
             '" stroke="var(--text-color)" stroke-opacity="' + (f ? 0.12 : 0.3) + '"/>';
      if (g.max) svg += '<text x="' + (g.L - 6) + '" y="' + (yy + 4) + '" text-anchor="end" ' + ink + '>' + swapHuman(Math.round(g.max * f)) + '</text>';
    });
    // x labels: start, middle, end of the range
    [0, 0.5, 1].forEach(function(f) {
      var a = f === 0 ? 'start' : (f === 1 ? 'end' : 'middle');
      svg += '<text x="' + (g.L + f * g.pw) + '" y="' + (g.H - 6) + '" text-anchor="' + a + '" ' + ink + '>' +
             clock(d.now - d.range + f * d.range, sec) + '</text>';
    });
    if (!pts.length || !g.max) {
      var msg = pts.length ? 'No swap active in this range' : 'No data yet - first sample within ' + d.interval + ' s';
      svg += '<text x="' + (g.L + g.pw / 2) + '" y="' + (g.T + g.ph / 2) + '" text-anchor="middle" ' + ink + '>' + msg + '</text>';
    }
    if (g.max) {
      // split into segments at gaps, so downtime is not drawn as a straight line
      var segs = [], cur = [];
      pts.forEach(function(p, i) {
        if (i && p[0] - pts[i - 1][0] > d.gap) { segs.push(cur); cur = []; }
        cur.push(p);
      });
      segs.push(cur);
      var base = g.T + g.ph;
      segs.forEach(function(s) {
        if (s.length === 1) {
          svg += '<circle cx="' + g.x(s[0][0]) + '" cy="' + g.y(s[0][1]) + '" r="2" fill="' + color + '"/>';
          return;
        }
        var line = s.map(function(p, i) { return (i ? 'L' : 'M') + g.x(p[0]).toFixed(1) + ',' + g.y(p[1]).toFixed(1); }).join('');
        svg += '<path d="' + line + 'L' + g.x(s[s.length - 1][0]).toFixed(1) + ',' + base + 'L' + g.x(s[0][0]).toFixed(1) + ',' + base +
               'Z" fill="' + color + '" fill-opacity="0.15"/>';
        svg += '<path d="' + line + '" fill="none" stroke="' + color + '" stroke-width="2" stroke-linejoin="round"/>';
      });
    }
    svg += '<line class="swaphx" y1="' + g.T + '" y2="' + (g.T + g.ph) + '" stroke="var(--text-color)" stroke-opacity="0.4" visibility="hidden"/>' +
           '<circle class="swaphd" r="4" fill="' + color + '" stroke="var(--background-color, #fff)" stroke-width="2" visibility="hidden"/></svg>' +
           '<div class="swaphtip" style="position:absolute; top:0; display:none; pointer-events:none; white-space:nowrap; padding:4px 8px;' +
           ' font-size:12px; border-radius:4px; background:var(--background-color, #fff); color:var(--text-color);' +
           ' border:1px solid rgba(128,128,128,0.4); box-shadow:0 2px 6px rgba(0,0,0,0.2);"></div>';
    box.html(svg + usageBar(g));
    if (st.mouse) hover(st.mouse); // keep the tooltip across the refresh
  }

  // current usage below the graph, styled like the CPU load bar of the dashboard (same colors
  // and the thresholds of Settings > Display Settings); the bar starts where the plot starts
  function usageBar(g) {
    var d = st.data, pct = d.total ? Math.round(d.used / d.total * 100) : 0;
    var txt = d.total ? swapHuman(d.used) + ' / ' + swapHuman(d.total) : 'no swap active';
    var alert = d.critical > 0 && pct >= d.critical ? '#f0000c' : (d.warning > 0 && pct >= d.warning ? '#e68a00' : '');
    return '<div style="display:flex; align-items:center; gap:6px; margin:8px ' + g.R + 'px 14px 0; font-size:12px;">' +
           '<span style="width:' + (g.L - 6) + 'px; flex:none; text-align:right; color:' + (alert || '#4f8a10') + ';">' + pct + '%</span>' +
           '<div style="flex:1; height:12px; background:var(--usage-disk-background-color, rgba(128,128,128,0.3));">' +
           '<div style="height:100%; width:' + pct + '%; background:' + (alert || 'var(--gray-400, #909090)') + ';"></div></div>' +
           '<span style="white-space:nowrap;">' + txt + '</span></div>';
  }

  // crosshair + tooltip: nearest sample to the pointer
  function hover(e) {
    st.mouse = e;
    var d = st.data; if (!d || !d.points.length) return;
    var g = geom(), mx = e.pageX - box.offset().left, best = null;
    if (mx < g.L || mx > g.W - g.R || e.pageY - box.offset().top > g.H) return leave(); // below the graph: usage bar
    d.points.forEach(function(p) { if (!best || Math.abs(g.x(p[0]) - mx) < Math.abs(g.x(best[0]) - mx)) best = p; });
    var px = g.x(best[0]), py = g.y(best[1]);
    box.find('.swaphx').attr({x1: px, x2: px, visibility: 'visible'});
    box.find('.swaphd').attr({cx: px, cy: py, visibility: g.max ? 'visible' : 'hidden'});
    var txt = clock(best[0], true) + ' - ' + (best[2] ? swapHuman(best[1]) + ' of ' + swapHuman(best[2]) +
              ' (' + Math.round(best[1] / best[2] * 100) + '%)' : 'no swap active');
    var tip = box.find('.swaphtip').text(txt).show();
    tip.css('left', Math.max(0, Math.min(px + 10, g.W - tip.outerWidth())) + 'px');
  }
  function leave() { st.mouse = null; box.find('.swaphx,.swaphd').attr('visibility', 'hidden'); box.find('.swaphtip').hide(); }

  function load() {
    $.post('/plugins/swap-manager/include/exec.php', {action: 'history', range: st.range}, function(r) {
      st.data = r; draw();
      // refresh with the sampling interval (no point in asking faster), at least every 5s
      clearTimeout(st.timer);
      st.timer = setTimeout(load, Math.max(5, r.interval) * 1000);
    }, 'json');
  }

  box.css('position', 'relative').on('mousemove', hover).on('mouseleave', leave);
  $(window).on('resize', draw);
  load();
  return {range: function(r) { st.range = r; load(); }};
}
