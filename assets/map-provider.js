(() => {
  // Fond OpenStreetMap sans clé API + styles cartographiques du jeu.
  if (!window.L || !L.tileLayer || !L.geoJSON) return;

  const originalTileLayer = L.tileLayer.bind(L);
  const originalGeoJSON = L.geoJSON.bind(L);

  function resolveStyle(styleSpec, feature) {
    return typeof styleSpec === "function"
      ? (styleSpec(feature) || {})
      : (styleSpec || {});
  }

  function isActiveExtractionStyle(baseStyle = {}) {
    return (baseStyle?.weight || 0) >= 4;
  }

  function gameStyle(feature, baseStyle = {}, hasActiveExtraction = false) {
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

    // Zones d'extraction : toutes visibles avant le tirage.
    // Dès qu'une zone devient active, les autres disparaissent visuellement.
    if (p.zone_type === "extraction") {
      const active = isActiveExtractionStyle(baseStyle);

      if (hasActiveExtraction && !active) {
        return {
          ...baseStyle,
          stroke: false,
          fill: false,
          weight: 0,
          opacity: 0,
          fillOpacity: 0,
          interactive: false
        };
      }

      return {
        ...baseStyle,
        color: active ? "#b91c1c" : "#d94a4a",
        weight: active ? 6 : 3,
        opacity: 1,
        fillColor: active ? "#ff6b6b" : "#ff9a9a",
        fillOpacity: active ? 0.52 : 0.30,
        dashArray: null,
        stroke: true,
        fill: true,
        interactive: true
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
    const features = Array.isArray(geojson?.features) ? geojson.features : [];

    const initialHasActiveExtraction = features.some((feature) =>
      feature?.properties?.zone_type === "extraction" &&
      isActiveExtractionStyle(resolveStyle(requestedStyle, feature))
    );

    const wrappedStyle = (feature) =>
      gameStyle(feature, resolveStyle(requestedStyle, feature), initialHasActiveExtraction);

    const layer = originalGeoJSON(geojson, { ...options, style: wrappedStyle });
    const originalSetStyle = layer.setStyle.bind(layer);

    layer.setStyle = function patchedSetStyle(styleSpec) {
      const hasActiveExtraction = features.some((feature) =>
        feature?.properties?.zone_type === "extraction" &&
        isActiveExtractionStyle(resolveStyle(styleSpec, feature))
      );

      return originalSetStyle((feature) =>
        gameStyle(feature, resolveStyle(styleSpec, feature), hasActiveExtraction)
      );
    };

    return layer;
  };

  const style = document.createElement("style");
  style.textContent = `
    .leaflet-tile.osm-dark-tiles {
      filter: brightness(0.72) contrast(1.12) saturate(0.55);
    }
    .leaflet-overlay-pane path {
      transition: opacity .25s ease, fill-opacity .25s ease, stroke-width .25s ease;
    }
  `;
  document.head.appendChild(style);
})();
