(() => {
  // Fond OpenStreetMap sans clé API + styles de jeu renforcés.
  if (!window.L || !L.tileLayer || !L.geoJSON) return;

  const originalTileLayer = L.tileLayer.bind(L);
  const originalGeoJSON = L.geoJSON.bind(L);

  function gameStyle(feature, baseStyle = {}) {
    const p = feature?.properties || {};

    if (p.zone_type === "perimeter") {
      return {
        ...baseStyle,
        color: "#ff3b30",
        weight: 4,
        opacity: 0.98,
        dashArray: null,
        fillColor: "#ff3b30",
        fillOpacity: 0.02
      };
    }

    if (p.zone_type === "prison") {
      return {
        ...baseStyle,
        color: "#ff453a",
        weight: 3,
        opacity: 1,
        fillColor: "#ff453a",
        fillOpacity: 0.22,
        dashArray: null
      };
    }

    if (p.zone_type === "extraction") {
      const active = (baseStyle?.weight || 0) >= 4;
      return {
        ...baseStyle,
        color: "#6dff5f",
        weight: active ? 5 : 3,
        opacity: 1,
        fillColor: "#6dff5f",
        fillOpacity: active ? 0.36 : 0.16,
        dashArray: active ? null : "6 4"
      };
    }

    return baseStyle;
  }

  L.tileLayer = function patchedTileLayer(url, options = {}) {
    if (typeof url === "string" && url.includes("basemaps.cartocdn.com")) {
      return originalTileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        ...options,
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
        className: "osm-dark-tiles"
      });
    }
    return originalTileLayer(url, options);
  };

  L.geoJSON = function patchedGeoJSON(geojson, options = {}) {
    const requestedStyle = options.style;

    const wrappedStyle = (feature) => {
      const base = typeof requestedStyle === "function"
        ? (requestedStyle(feature) || {})
        : (requestedStyle || {});
      return gameStyle(feature, base);
    };

    const layer = originalGeoJSON(geojson, { ...options, style: wrappedStyle });
    const originalSetStyle = layer.setStyle.bind(layer);

    layer.setStyle = function patchedSetStyle(style) {
      if (typeof style === "function") {
        return originalSetStyle((feature) => gameStyle(feature, style(feature) || {}));
      }
      return originalSetStyle((feature) => gameStyle(feature, style || {}));
    };

    return layer;
  };

  const style = document.createElement("style");
  style.textContent = `
    .leaflet-tile.osm-dark-tiles {
      filter: brightness(0.72) contrast(1.12) saturate(0.55);
    }
  `;
  document.head.appendChild(style);
})();
