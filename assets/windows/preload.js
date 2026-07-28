const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("contextMeter", {
  onSnapshot(callback) {
    ipcRenderer.on("snapshot", (_event, snapshot) => callback(snapshot));
  },
  setHovered(source, hovered) {
    ipcRenderer.send("hover", { source, hovered });
  },
  closeDetails() {
    ipcRenderer.send("close-details");
  },
});
