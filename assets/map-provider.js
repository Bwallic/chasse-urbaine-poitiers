(() => {
  // Fond OpenStreetMap sans clé API + styles cartographiques du jeu.
  if (!window.L || !L.tileLayer || !L.geoJSON) return;

  const originalTileLayer = L.tileLayer.bind(L);
  const originalGeoJSON = L.geoJSON.bind(L);

  function gameStyle(feature, baseStyle = {}) {
    const p = feature?.properties || {};

    // Périmètre de jeu : rouge, pointillé, sans remplissage visible.
    if (p.zone_type === "perimeter") {
      return {
        ...baseStyle,
        color: "#d94a4a",
        weight: 3,
        opacity: 1,
        dashArray: "10 8",
        lineCap: "round",
        fillColor: "#d94a4a",
        fillOpacity: 0
      };
    }

    // Prison : jaune franc, contour et remplissage bien visibles.
    if (p.zone_type === "prison") {
      return {
        ...baseStyle,
        color: "#e6b800",
        weight: 3,
        opacity: 1,
        fillColor: "#ffe66d",
        fillOpacity: 0.38,
        dashArray: null
      };
    }

    // Zones d'extraction : rouge pastel translucide.
    if (p.zone_type === "extraction") {
      const active = (baseStyle?.weight || 0) >= 4;
      return {
        ...baseStyle,
        color: active ? "#c93434" : "#d94a4a",
        weight: active ? 5 : 3,
        opacity: 1,
        fillColor: active ? "#ff7f7f" : "#ff9a9a",
        fillOpacity: active ? 0.42 : 0.30,
        dashArray: null
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
