import { requireNativeModule } from "expo-modules-core";
const NativeModule = requireNativeModule("VideoEffectsSdkReactNativeModule");
class TsvbVideoEffects {
    _state = {
        isInitialized: false,
        isReady: false,
        activeEffect: "none",
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
            error: null,
        };
        this.emit({ type: "stateChange", state: this.getState() });
    }
    // --- Private ---
    ensureInitialized() {
        if (!this._state.isInitialized) {
            throw new Error("TSVB SDK is not initialized. Call initialize() first.");
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
        for (const cb of this._subscribers) {
            try {
                cb(event);
            }
            catch {
                // Don't let subscriber errors propagate
            }
        }
    }
}
export const tsvbVideoEffects = new TsvbVideoEffects();
export * from "./VideoEffectsSdkReactNativeModule.types";
export { TsvbVideoEffects };
export { NativeModule as VideoEffectsSdkReactNativeModule };
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.js.map