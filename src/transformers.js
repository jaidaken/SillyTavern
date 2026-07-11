import path from 'node:path';
import fs from 'node:fs';
import process from 'node:process';
import { Buffer } from 'node:buffer';

import { pipeline, env, RawImage } from '@huggingface/transformers';
import { getConfigValue } from './util.js';
import { serverDirectory } from './server-directory.js';
import { log } from './log.js';

configureTransformers();

function configureTransformers() {
    const wasmEnv = env.backends?.onnx?.wasm;
    if (!wasmEnv) {
        log.tok.warn('onnxruntime-web WASM env is unavailable; skipping thread/path configuration.');
        return;
    }
    // Limit the number of threads to 1 to avoid issues on Android
    wasmEnv.numThreads = 1;
    // Local WASM (no CDN). transformers ships .wasm in a nested onnxruntime-web; Nix may hoist it,
    // so use whichever of the nested or top-level dist actually exists.
    const wasmCandidates = [
        path.join(serverDirectory, 'node_modules', '@huggingface', 'transformers', 'node_modules', 'onnxruntime-web', 'dist'),
        path.join(serverDirectory, 'node_modules', 'onnxruntime-web', 'dist'),
    ];
    wasmEnv.wasmPaths = (wasmCandidates.find(d => fs.existsSync(d)) ?? wasmCandidates[0]) + path.sep;
}

/**
 * @typedef {object} TaskDefinition
 * @property {string} defaultModel Model to use when config specifies none
 * @property {any} pipeline Cached pipeline instance for the task
 * @property {string} configField config.yaml path for the model override
 * @property {import('@huggingface/transformers').DataType} dtype Model weights variant to load
 * @property {string} [currentModel] Model the cached pipeline was created with
 */

/** @type {Record<string, TaskDefinition>} */
const tasks = {
    'text-classification': {
        defaultModel: 'Cohee/distilbert-base-uncased-go-emotions-onnx',
        pipeline: null,
        configField: 'extensions.models.classification',
        dtype: 'q8',
    },
    'image-to-text': {
        defaultModel: 'Xenova/vit-gpt2-image-captioning',
        pipeline: null,
        configField: 'extensions.models.captioning',
        dtype: 'q8',
    },
    'feature-extraction': {
        defaultModel: 'Xenova/all-mpnet-base-v2',
        pipeline: null,
        configField: 'extensions.models.embedding',
        dtype: 'q8',
    },
    'automatic-speech-recognition': {
        defaultModel: 'Xenova/whisper-small',
        pipeline: null,
        configField: 'extensions.models.speechToText',
        dtype: 'q8',
    },
    'text-to-speech': {
        defaultModel: 'Xenova/speecht5_tts',
        pipeline: null,
        configField: 'extensions.models.textToSpeech',
        dtype: 'fp32',
    },
};

/**
 * Gets a RawImage object from a base64-encoded image.
 * @param {string} image Base64-encoded image
 * @returns {Promise<RawImage|null>} Object representing the image
 */
export async function getRawImage(image) {
    try {
        const buffer = Buffer.from(image, 'base64');
        const byteArray = new Uint8Array(buffer);
        const blob = new Blob([byteArray]);

        const rawImage = await RawImage.fromBlob(blob);
        return rawImage;
    } catch {
        return null;
    }
}

/**
 * Gets the model to use for a given transformers.js task.
 * @param {string} task The task to get the model for
 * @returns {string} The model to use for the given task
 */
function getModelForTask(task) {
    const defaultModel = tasks[task].defaultModel;

    try {
        const model = getConfigValue(tasks[task].configField, null);
        return model || defaultModel;
    } catch (error) {
        log.tok.warn('Failed to read config.yaml, using default classification model.');
        return defaultModel;
    }
}

async function migrateCacheToDataDir() {
    const oldCacheDir = path.join(process.cwd(), 'cache');
    const newCacheDir = path.join(globalThis.DATA_ROOT, '_cache');

    if (!(await fs.promises.stat(newCacheDir).catch(() => null))) {
        await fs.promises.mkdir(newCacheDir, { recursive: true });
    }

    const oldStats = await fs.promises.stat(oldCacheDir).catch(() => null);
    if (oldStats && oldStats.isDirectory()) {
        const files = await fs.promises.readdir(oldCacheDir);

        if (files.length === 0) {
            return;
        }

        log.tok.info('Migrating model cache files to data directory. Please wait...');

        for (const file of files) {
            try {
                const oldPath = path.join(oldCacheDir, file);
                const newPath = path.join(newCacheDir, file);
                await fs.promises.cp(oldPath, newPath, { recursive: true, force: true });
                await fs.promises.rm(oldPath, { recursive: true, force: true });
            } catch (error) {
                log.tok.warn('Failed to migrate cache file. The model will be re-downloaded.', error);
            }
        }
    }
}

/**
 * Gets the transformers.js pipeline for a given task.
 * @template {import('@huggingface/transformers').PipelineType} T
 * @param {T} task The task to get the pipeline for
 * @param {string} forceModel The model to use for the pipeline, if any
 * @returns {Promise<import('@huggingface/transformers').AllTasks[T]>} The transformers.js pipeline
 */
export async function getPipeline(task, forceModel = '') {
    await migrateCacheToDataDir();

    if (tasks[task].pipeline) {
        if (forceModel === '' || tasks[task].currentModel === forceModel) {
            return tasks[task].pipeline;
        }
        log.tok.info('Disposing transformers.js pipeline for for task', task, 'with model', tasks[task].currentModel);
        await tasks[task].pipeline.dispose();
    }

    const cacheDir = path.join(globalThis.DATA_ROOT, '_cache');
    const model = forceModel || getModelForTask(task);
    const localOnly = !getConfigValue('extensions.models.autoDownload', true, 'boolean');
    log.tok.info('Initializing transformers.js pipeline for task', task, 'with model', model);
    const instance = await pipeline(task, model, { cache_dir: cacheDir, dtype: tasks[task].dtype ?? 'q8', local_files_only: localOnly });
    tasks[task].pipeline = instance;
    tasks[task].currentModel = model;
    return instance;
}

export default {
    getRawImage,
    getPipeline,
};
