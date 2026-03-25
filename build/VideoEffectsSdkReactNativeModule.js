import { requireNativeModule } from "expo-modules-core";
const NativeModule = requireNativeModule("VideoEffectsSdkReactNativeModule");
class TsvbVideoEffects {
    _state = {
        isInitialized: false,
        isReady: false,
        activeEffect: "none",
        isEffectsUnavailable: false,
        error: null,
    };
    _subscribers = new Set();
    async initialize(config) {
        const { trackId } = config;
        try {
            const result = await NativeModule.initialize(config.customerID, trackId);
            if (!result.success) {
                this.updateState({ error: result.error || "Initialization failed" });
                throw new Error(result.error || "Initialization failed");
            }
            this.updateState({
                isInitialized: true,
                isReady: true,
                error: null,
            });
            return result;
        }
        catch (error) {
            const msg = `Failed to initialize TSVB SDK: ${error}`;
            this.updateState({ error: msg });
            throw new Error(msg);
        }
    }
    async enableBlur(options) {
        this.ensureInitialized();
        this.ensureEffectsAvailable();
        try {
            const power = options?.power ?? 0.5;
            await NativeModule.enableBlurBackground(power);
            this.updateState({ activeEffect: "blur", error: null });
        }
        catch (error) {
            const msg = `Failed to enable blur: ${error}`;
            this.emitError(msg, true);
            throw new Error(msg);
        }
    }
    async enableReplaceBackground(options) {
        this.ensureInitialized();
        this.ensureEffectsAvailable();
        try {
            await NativeModule.enableReplaceBackground(options.image);
            this.updateState({ activeEffect: "replace", error: null });
        }
        catch (error) {
            const msg = `Failed to enable background replacement: ${error}`;
            this.emitError(msg, true);
            throw new Error(msg);
        }
    }
    async disableEffects() {
        this.ensureInitialized();
        try {
            if (this._state.activeEffect === "blur") {
                await NativeModule.disableBlurBackground();
            }
            else if (this._state.activeEffect === "replace") {
                await NativeModule.disableReplaceBackground();
            }
            this.updateState({ activeEffect: "none", error: null });
        }
        catch (error) {
            const msg = `Failed to disable effects: ${error}`;
            this.emitError(msg, true);
            throw new Error(msg);
        }
    }
    getState() {
        return { ...this._state };
    }
    subscribe(callback) {
        this._subscribers.add(callback);
        return () => {
            this._subscribers.delete(callback);
        };
    }
    setDeviceOrientation(orientation) {
        NativeModule.setDeviceOrientation(orientation);
    }
    /** Set segmentation quality preset. Only effective on iOS — Android handles this internally. */
    setSegmentationPreset(preset) {
        NativeModule.setSegmentationPreset(preset);
    }
    cleanup() {
        try {
            NativeModule.cleanup();
        }
        catch {
            // Ignore cleanup errors
        }
        this._state = {
            isInitialized: false,
            isReady: false,
            activeEffect: "none",
            isEffectsUnavailable: false,
            error: null,
        };
        this.emit({ type: "stateChange", state: this.getState() });
    }
    // --- Private ---
    /** Query native for fallback state and update local state. Returns true if effects are unavailable. */
    checkEffectsAvailability() {
        try {
            const unavailable = NativeModule.isEffectsUnavailable();
            if (unavailable !== this._state.isEffectsUnavailable) {
                this.updateState({ isEffectsUnavailable: unavailable });
            }
            return unavailable;
        }
        catch {
            return false;
        }
    }
    ensureInitialized() {
        if (!this._state.isInitialized) {
            throw new Error("TSVB SDK is not initialized. Call initialize() first.");
        }
    }
    ensureEffectsAvailable() {
        if (this.checkEffectsAvailability()) {
            throw new Error("Effects unavailable — camera is running in fallback mode without effects pipeline.");
        }
    }
    updateState(partial) {
        this._state = { ...this._state, ...partial };
        this.emit({ type: "stateChange", state: this.getState() });
    }
    emitError(error, recoverable) {
        this.emit({ type: "error", error, recoverable });
    }
    emit(event) {
        this._subscribers.forEach(cb => {
            try {
                cb(event);
            }
            catch {
                // Don't let subscriber errors propagate
            }
        });
    }
}
export const tsvbVideoEffects = new TsvbVideoEffects();
export * from "./VideoEffectsSdkReactNativeModule.types";
export { TsvbVideoEffects };
export { NativeModule as VideoEffectsSdkReactNativeModule };
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.js.map