declare global {
  interface Window {
    connect: () => Promise<void>;
    sendCommand: () => Promise<void>;
    quickCmd: (text: string) => void;
    autoResize: (element: HTMLTextAreaElement) => void;
    updateConnectionMode: () => void;
  }
}

export {};
