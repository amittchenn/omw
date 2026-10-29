// The map runs on Mapbox GL, like Snap Map: vector tiles drawn on the phone, so zooming and pinching are smooth, it can tilt
// and turn, and there are 3D buildings. Mapbox's Standard style switches to its night lighting when the phone is in dark mode.
// Without a Mapbox token it falls back to MapLibre (the open-source version) with OpenStreetMap tiles.
//
// The app's map code (index.html, maptab.js) uses a small Leaflet-style set of calls: L.map, L.marker with an HTML icon,
// L.polyline, L.layerGroup, flyTo, fitBounds... This file gives it exactly those, drawn with GL. Zoom levels stay Leaflet's
// (GL's zoom is one less, since its tiles are 512 px), so the rest of the app didn't have to change.
(() => {
  const MAPBOX = "https://cdn.jsdelivr.net/npm/mapbox-gl@3.31.0/dist/mapbox-gl";
  const MAPLIBRE = "https://cdn.jsdelivr.net/npm/maplibre-gl@5.24.0/dist/maplibre-gl";
  const toLL = a => Array.isArray(a) ? { lat: +a[0], lng: +a[1] } : { lat: +a.lat, lng: +a.lng };
  const toLngLat = a => { const p = toLL(a); return [p.lng, p.lat]; };
  const glZoom = z => z - 1, lfZoom = z => z + 1;
  let ids = 0;

  class Evented {
    on(type, fn) { ((this._ev ||= {})[type] ||= []).push(fn); return this; }
    off(type, fn) { if (this._ev?.[type]) this._ev[type] = fn ? this._ev[type].filter(f => f !== fn) : []; return this; }
    fire(type, e = {}) { (this._ev?.[type] || []).slice().forEach(f => f.call(this, { ...e, type, target: this })); return this; }
  }

  // ---------- a box of points (fitBounds, getBounds) ----------
  class Bounds {
    constructor(points = []) { this.s = 90; this.w = 180; this.n = -90; this.e = -180; points.forEach(p => this.extend(p)); }
    static of(b) { return b instanceof Bounds ? b : new Bounds(b); }
    extend(p) {
      if (p instanceof Bounds) { this.extend([p.s, p.w]); return this.extend([p.n, p.e]); }
      const { lat, lng } = toLL(p);
      if (!isFinite(lat) || !isFinite(lng)) return this;
      this.s = Math.min(this.s, lat); this.n = Math.max(this.n, lat); this.w = Math.min(this.w, lng); this.e = Math.max(this.e, lng);
      return this;
    }
    pad(r) { const h = (this.n - this.s) * r, w = (this.e - this.w) * r; const b = new Bounds(); Object.assign(b, { s: this.s - h, n: this.n + h, w: this.w - w, e: this.e + w }); return b; }
    isValid() { return this.s <= this.n; }
    toGL() { return [[this.w, this.s], [this.e, this.n]]; }
  }

  // ---------- markers: any HTML, pinned to a spot ----------
  class Marker extends Evented {
    constructor(latlng, o = {}) {
      super();
      this._ll = toLL(latlng); this.o = o;
      this._el = document.createElement("div");
      this._el.className = "gl-marker";
      if (o.interactive === false) this._el.style.pointerEvents = "none";
      this._el.style.zIndex = String(o.zIndexOffset || 0);
      this._el.addEventListener("click", e => { if (this._ev?.click) { e.stopPropagation(); this.fire("click", { originalEvent: e }); } });
      this.setIcon(o.icon || { html: "", iconSize: [0, 0], iconAnchor: [0, 0] });
    }
    setIcon(icon) {
      this._icon = icon;
      const [w, h] = icon.iconSize || [0, 0];
      Object.assign(this._el.style, { width: `${w}px`, height: `${h}px` });
      const tip = this._tip;
      this._el.innerHTML = icon.html || "";
      if (icon.className) this._el.classList.add(...icon.className.split(" ").filter(Boolean));
      if (tip) this._el.append(tip);
      this._gl?.setOffset(this._offset());
      return this;
    }
    _offset() { const [ax, ay] = this._icon.iconAnchor || [0, 0]; return [-ax, -ay]; }
    bindTooltip(html, o = {}) {
      this._tip?.remove();
      const t = document.createElement("div");
      t.className = `gl-tip ${o.permanent ? "permanent" : ""} ${o.direction || "top"} ${o.className || ""}`;
      t.innerHTML = html;
      const [ax, ay] = this._icon.iconAnchor || [0, 0], [ox, oy] = o.offset || [0, 0];
      Object.assign(t.style, { left: `${ax + ox}px`, top: `${ay + oy}px` });
      this._tip = t; this._el.append(t);
      return this;
    }
    getElement() { return this._el; }
    getLatLng() { return { ...this._ll }; }
    setLatLng(a) { this._ll = toLL(a); this._gl?.setLngLat([this._ll.lng, this._ll.lat]); return this; }
    addTo(target) { target._add(this); return this; }
    remove() { (this._group || this._map)?._drop(this); return this; }
    _show(m) { this._gl ||= new m._lib.Marker({ element: this._el, anchor: "top-left", offset: this._offset() }).setLngLat([this._ll.lng, this._ll.lat]).addTo(m._gl); }
    _hide() { this._gl?.remove(); this._gl = null; }
  }

  // a small round dot (the start of a route)
  const circleMarker = (latlng, o = {}) => {
    const d = 2 * (o.radius || 6) + 2 * (o.weight || 0);
    return new Marker(latlng, { interactive: false, icon: { iconSize: [d, d], iconAnchor: [d / 2, d / 2],
      html: `<div style="width:${d}px;height:${d}px;box-sizing:border-box;border-radius:50%;border:${o.weight || 0}px solid ${o.color || "#fff"};background:${o.fillColor || o.color || "#1e88ff"};opacity:${o.fillOpacity ?? 1}"></div>` } });
  };

  // ---------- lines and areas, drawn by GL itself ----------
  class Shape extends Evented {
    constructor(o) { super(); this.o = { ...o }; this._id = `omw-${++ids}`; }
    addTo(target) { target._add(this); return this; }
    remove() { (this._group || this._map)?._drop(this); return this; }
    _show(m) {
      const gl = m._gl;
      if (!m._styled) return;  // added once the style is in (and again after it changes)
      if (gl.getSource(this._id)) return;
      gl.addSource(this._id, { type: "geojson", data: this._data() });
      this._layers(m).forEach(l => gl.addLayer(l));
    }
    _hide(m) {
      const gl = m?._gl;
      if (!gl?.style) return;
      this._layerIds().forEach(id => gl.getLayer(id) && gl.removeLayer(id));
      if (gl.getSource(this._id)) gl.removeSource(this._id);
    }
    _refresh() { this._map?._gl?.getSource(this._id)?.setData(this._data()); }
    _slot(m) { return m._lib === window.mapboxgl ? { slot: "middle" } : {}; }  // Mapbox Standard: under the labels and 3D buildings
  }
  class Polyline extends Shape {
    constructor(lls, o) { super(o); this._lls = lls.map(toLL); }
    _data() { return { type: "Feature", geometry: { type: "LineString", coordinates: this._lls.map(p => [p.lng, p.lat]) } }; }
    _layerIds() { return [this._id]; }
    _paint() {
      const o = this.o, w = o.weight || 3, dash = o.dashArray ? String(o.dashArray).split(/[ ,]+/).map(Number) : null;
      return { "line-color": o.color || "#1e88ff", "line-width": w, "line-opacity": o.opacity ?? 1,
               ...(dash ? { "line-dasharray": [dash[0] <= 1 ? 0 : dash[0] / w, dash[1] / w] } : {}) };
    }
    _layers(m) { return [{ id: this._id, type: "line", source: this._id, ...this._slot(m), layout: { "line-cap": "round", "line-join": "round" }, paint: this._paint() }]; }
    setStyle(o) {
      Object.assign(this.o, o);
      const gl = this._map?._gl;
      if (gl?.getLayer(this._id)) {
        const p = this._paint();
        if (!("line-dasharray" in p)) p["line-dasharray"] = [1, 0];
        Object.entries(p).forEach(([k, v]) => gl.setPaintProperty(this._id, k, v));
      }
      return this;
    }
    bringToFront() { const gl = this._map?._gl; if (gl?.getLayer(this._id)) gl.moveLayer(this._id); return this; }
    setLatLngs(lls) { this._lls = lls.map(toLL); this._refresh(); return this; }
    getBounds() { return new Bounds(this._lls); }
  }
  class Circle extends Shape {  // a circle in meters (how sure your phone is of where you are)
    constructor(latlng, o) { super(o); this._ll = toLL(latlng); this._r = o.radius || 10; }
    _data() {
      const { lat, lng } = this._ll, dy = this._r / 111320, dx = dy / Math.cos(lat * Math.PI / 180);
      const ring = Array.from({ length: 49 }, (_, i) => { const a = (i / 48) * 2 * Math.PI; return [lng + dx * Math.cos(a), lat + dy * Math.sin(a)]; });
      return { type: "Feature", geometry: { type: "Polygon", coordinates: [ring] } };
    }
    _layerIds() { return [this._id, `${this._id}-edge`]; }
    _layers(m) {
      const c = this.o.color || "#1e88ff";
      return [{ id: this._id, type: "fill", source: this._id, ...this._slot(m), paint: { "fill-color": this.o.fillColor || c, "fill-opacity": this.o.fillOpacity ?? .2 } },
              { id: `${this._id}-edge`, type: "line", source: this._id, ...this._slot(m), paint: { "line-color": c, "line-width": this.o.weight ?? 1, "line-opacity": .6 } }];
    }
    setLatLng(a) { this._ll = toLL(a); this._refresh(); return this; }
    setRadius(r) { this._r = r; this._refresh(); return this; }
  }

  // ---------- groups (clear them all at once) ----------
  class Group {
    constructor() { this._items = new Set(); this._map = null; }
    addTo(m) { if (this._map !== m) { this._map = m; this._items.forEach(i => m._attach(i)); } return this; }
    remove() { const m = this._map; this._items.forEach(i => m?._detach(i)); this._map = null; return this; }
    _add(i) { i._group = this; this._items.add(i); if (this._map) this._map._attach(i); }
    _drop(i) { this._items.delete(i); i._group = null; this._map?._detach(i); }
    clearLayers() { [...this._items].forEach(i => this._drop(i)); return this; }
    getLayers() { return [...this._items]; }
  }

  // ---------- the map ----------
  class GLMap extends Evented {
    constructor(id) {
      super();
      this._box = document.getElementById(id);
      this._center = { lat: 37.7849, lng: -122.4094 }; this._zoom = 13;
      this._live = new Set();  // everything on the map right now
      this._gl = null; this._lib = null; this._styled = false;
      this._corners = {};
      for (const c of ["top-left", "top-right", "bottom-left", "bottom-right"]) {
        const d = document.createElement("div"); d.className = `gl-corner ${c}`; this._box.append(d); this._corners[c] = d;
      }
    }
    // the style and library come once the server says whether there's a Mapbox token
    async start(token, dark) {
      const lib = token ? "mapboxgl" : "maplibregl";
      if (!window[lib]) await load(token ? MAPBOX : MAPLIBRE);
      this._lib = window[lib];
      if (token) this._lib.accessToken = token;
      const night = () => dark?.matches;
      const gl = this._gl = new this._lib.Map({
        container: this._box, center: [this._center.lng, this._center.lat], zoom: glZoom(this._zoom),
        style: token ? "mapbox://styles/mapbox/standard" : osmStyle(night()),
        ...(token ? { config: { basemap: { lightPreset: night() ? "night" : "day", showPointOfInterestLabels: true, showTransitLabels: false } } } : {}),
        attributionControl: false, logoPosition: "bottom-left", pitchWithRotate: true, dragRotate: true, cooperativeGestures: false,
        fadeDuration: 150,
      });
      // the corners (the locate button…) sit over the map like before
      Object.values(this._corners).forEach(c => this._box.append(c));
      gl.addControl(new this._lib.AttributionControl({ compact: true }), "bottom-left");
      gl.on("style.load", () => { this._styled = true; this._live.forEach(i => i instanceof Shape && i._show(this)); });
      gl.on("click", e => {
        if (e.originalEvent?.target?.closest?.(".gl-marker, .gl-corner")) return;  // a marker or a button, not the map
        this.fire("click", { latlng: { lat: e.lngLat.lat, lng: e.lngLat.lng }, originalEvent: e.originalEvent });
      });
      gl.on("moveend", () => this.fire("moveend"));
      gl.on("movestart", () => this.fire("movestart"));
      gl.on("zoomend", () => this.fire("zoomend"));
      dark?.addEventListener?.("change", () => {
        if (token) gl.setConfigProperty("basemap", "lightPreset", night() ? "night" : "day");
        else { this._styled = false; gl.setStyle(osmStyle(night())); }
      });
      this._live.forEach(i => i._show(this));
      if (this._pending) { const [b, o] = this._pending; this._pending = null; this.fitBounds(b, o); }
      this.fire("ready");
      return this;
    }
    _add(i) { i._group = null; this._attach(i); }
    _drop(i) { this._detach(i); }
    _attach(i) { i._map = this; this._live.add(i); if (this._gl) i._show(this); }
    _detach(i) { this._live.delete(i); if (this._gl) i._hide(this); i._map = null; }
    addLayer(i) { this._add(i); return this; }
    removeLayer(i) { this._drop(i); return this; }

    getCenter() { if (this._gl) { const c = this._gl.getCenter(); return { lat: c.lat, lng: c.lng }; } return { ...this._center }; }
    getZoom() { return this._gl ? lfZoom(this._gl.getZoom()) : this._zoom; }
    setView(c, z = this.getZoom()) {
      this._center = toLL(c); this._zoom = z;
      this._gl?.jumpTo({ center: toLngLat(c), zoom: glZoom(z) });
      return this;
    }
    flyTo(c, z = this.getZoom()) {
      if (!this._gl) return this.setView(c, z);
      this._gl.flyTo({ center: toLngLat(c), zoom: glZoom(z), essential: true, speed: 1.6, curve: 1.3 });
      return this;
    }
    fitBounds(b, o = {}) {
      const box = Bounds.of(b);
      if (!box.isValid()) return this;
      if (!this._gl) { this._pending = [box, o]; this._center = { lat: (box.s + box.n) / 2, lng: (box.w + box.e) / 2 }; return this; }
      const [l, t] = o.paddingTopLeft || o.padding || [0, 0], [r, btm] = o.paddingBottomRight || o.padding || [0, 0];
      const W = this._box.clientWidth, H = this._box.clientHeight;
      // padding can't take up the whole map (GL refuses); shrink it to fit
      const kx = l + r > W - 60 ? (W - 60) / (l + r) : 1, ky = t + btm > H - 60 ? (H - 60) / (t + btm) : 1;
      this._gl.fitBounds(box.toGL(), { padding: { left: l * kx, right: r * kx, top: t * ky, bottom: btm * ky },
        maxZoom: glZoom(o.maxZoom || 17), duration: 700, essential: true });
      return this;
    }
    invalidateSize() { this._gl?.resize(); return this; }
    distance(a, b) {  // meters
      const p = toLL(a), q = toLL(b), r = Math.PI / 180;
      const x = Math.sin((q.lat - p.lat) * r / 2) ** 2 + Math.cos(p.lat * r) * Math.cos(q.lat * r) * Math.sin((q.lng - p.lng) * r / 2) ** 2;
      return 12742000 * Math.asin(Math.sqrt(x));
    }
    corner(where) { return this._corners[where]; }
  }

  const osmStyle = dark => ({
    version: 8,
    sources: { osm: { type: "raster", tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"], tileSize: 256, maxzoom: 19,
                      attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>' } },
    layers: [{ id: "osm", type: "raster", source: "osm",
               paint: dark ? { "raster-brightness-max": .62, "raster-contrast": .1, "raster-saturation": -.2 } : { "raster-saturation": .25 } }],
  });
  const load = base => new Promise((ok, no) => {
    const css = document.createElement("link"); css.rel = "stylesheet"; css.href = `${base}.css`; document.head.append(css);
    const s = document.createElement("script"); s.src = `${base}.js`; s.onload = ok; s.onerror = () => no(new Error("The map didn't load."));
    document.head.append(s);
  });

  // a button (or anything) in a corner of the map, like Leaflet's controls
  const Control = { extend: def => class {
    constructor() { this.options = { ...def.options }; }
    addTo(m) { const el = def.onAdd.call(this, m); el.classList.add("gl-ctrl"); m.corner(this.options.position.replace(/^(top|bottom)/, "$1-")).append(el); return this; }
  } };

  window.L = {
    map: id => new GLMap(id),
    marker: (ll, o) => new Marker(ll, o),
    divIcon: o => ({ ...o }),
    polyline: (lls, o) => new Polyline(lls, o),
    circle: (ll, o) => new Circle(ll, o),
    circleMarker,
    layerGroup: () => new Group(),
    latLngBounds: pts => new Bounds(pts),
    Control,
    DomUtil: { create: (tag, cls) => Object.assign(document.createElement(tag), { className: cls || "" }) },
    DomEvent: { disableClickPropagation: el => ["click", "dblclick", "mousedown", "pointerdown"].forEach(t => el.addEventListener(t, e => e.stopPropagation())) },
  };
})();
