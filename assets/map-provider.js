(() => {
  // Remplace le fond CARTO de la V1 par OpenStreetMap Standard.
  // Objectif : aucun token/API key à gérer côté client.
  if (!window.L || !L.tileLayer) return;

  const originalTileLayer = L.tileLayer;

  L.tileLayer = function patchedTileLayer(url, options = {}) {
    if (typeof url === "string" && url.includes("basemaps.cartocdn.com")) {
      return originalTileLayer.call(L, "https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        ...options,
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
        className: "osm-dark-tiles"
      });
    }
    return originalTileLayer.call(L, url, options);
  };

  const style = document.createElement("style");
  style.textContent = `
    .leaflet-tile.osm-dark-tiles {
      filter: brightness(0.72) contrast(1.12) saturate(0.55);
    }
  `;
  document.head.appendChild(style);
})();
