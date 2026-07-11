import {
    activateSendButtons,
    addOneMessage,
    appendMediaToMessage,
    callPopup,
    characters,
    chat,
    chat_metadata,
    CONNECT_API_MAP,
    create_save,
    deactivateSendButtons,
    event_types,
    eventSource,
    extension_prompts,
    extractMessageFromData,
    Generate,
    generateQuietPrompt,
    getCharacters,
    getCurrentChatId,
    getRequestHeaders,
    getThumbnailUrl,
    main_api,
    max_context,
    menu_type,
    messageFormatting,
    name1,
    name2,
    online_status,
    openCharacterChat,
    reloadCurrentChat,
    renameChat,
    saveChatConditional,
    saveMetadata,
    saveReply,
    saveSettingsDebounced,
    selectCharacterById,
    sendGenerationRequest,
    sendStreamingRequest,
    sendSystemMessage,
    setExtensionPrompt,
    stopGeneration,
    streamingProcessor,
    substituteParams,
    substituteParamsExtended,
    this_chid,
    updateChatMetadata,
    updateMessageBlock,
    printMessages,
    clearChat,
    unshallowCharacter,
    deleteLastMessage,
    getCharacterCardFields,
    swipe_right,
    swipe_left,
    generateRaw,
    generateRawData,
    showSwipeButtons,
    hideSwipeButtons,
    deleteMessage,
    refreshSwipeButtons,
    swipe,
    isSwipingAllowed,
    swipeState,
    ensureMessageMediaIsArray,
    getMediaDisplay,
    getMediaIndex,
    scrollChatToBottom,
    scrollOnMediaLoad,
    getOneCharacter,
    getCharacterSource,
} from '../script.js';
import {
    extension_settings,
    getExtensionManifest,
    ModuleWorkerWrapper,
    openThirdPartyExtensionMenu,
    renderExtensionTemplate,
    renderExtensionTemplateAsync,
    saveMetadataDebounced,
    UNSET_VALUE,
    writeExtensionField,
    writeExtensionFieldBulk,
} from './extensions.js';
import { groups, openGroupChat, selected_group, unshallowGroupMembers } from './group-chats.js';
import { addLocaleData, getCurrentLocale, t, translate } from './i18n.js';
import { hideLoader, showLoader } from './loader.js';
import { loader } from './action-loader.js';
import { MacrosParser } from './macros.js';
import { getChatCompletionModel, oai_settings } from './openai.js';
import { callGenericPopup, Popup, POPUP_RESULT, POPUP_TYPE } from './popup.js';
import { power_user, registerDebugFunction } from './power-user.js';
import { getPresetManager } from './preset-manager.js';
import { humanizedDateTime, isMobile, shouldSendOnEnter } from './RossAscends-mods.js';
import { ScraperManager } from './scrapers.js';
import { executeSlashCommands, executeSlashCommandsWithOptions, registerSlashCommand } from './slash-commands.js';
import { SlashCommand } from './slash-commands/SlashCommand.js';
import { ARGUMENT_TYPE, SlashCommandArgument, SlashCommandNamedArgument } from './slash-commands/SlashCommandArgument.js';
import { SlashCommandEnumValue } from './slash-commands/SlashCommandEnumValue.js';
import { SlashCommandParser } from './slash-commands/SlashCommandParser.js';
import { tag_map, tags, importTags } from './tags.js';
import { getTextGenServer, textgenerationwebui_settings } from './textgen-settings.js';
import { tokenizers, getTextTokens, getTextTokensAsync, decodeTextTokensAsync, getTokenCount, getTokenCountAsync, getTokenizerModel } from './tokenizers.js';
import { ToolManager } from './tool-calling.js';
import { accountStorage } from './util/AccountStorage.js';
import { timestampToMoment, uuidv4, importFromExternalUrl } from './utils.js';
import { addGlobalVariable, addLocalVariable, decrementGlobalVariable, decrementLocalVariable, deleteGlobalVariable, deleteLocalVariable, existsGlobalVariable, existsLocalVariable, getGlobalVariable, getLocalVariable, incrementGlobalVariable, incrementLocalVariable, setGlobalVariable, setLocalVariable } from './variables.js';
import { convertCharacterBook, getWorldInfoPrompt, loadWorldInfo, reloadEditor, saveWorldInfo, updateWorldInfoList, world_names } from './world-info.js';
import { ChatCompletionService, TextCompletionService } from './custom-request.js';
import { ConnectionManagerRequestService } from './extensions/shared.js';
import { updateReasoningUI, parseReasoningFromString, getReasoningTemplateByName } from './reasoning.js';
import { IGNORE_SYMBOL } from './constants.js';
import { macros } from './macros/macro-system.js';
import { log } from './log.js';

// Mirrors MacrosParser's internal bridging so extensions keep the legacy (name, fn, description) signature,
// without calling the deprecated MacrosParser.registerMacro.
function registerContextMacro(key, value, description = '') {
    if (typeof key !== 'string') {
        throw new Error('Macro key must be a string');
    }

    key = key.trim();

    if (!key) {
        throw new Error('Macro key must not be empty or whitespace only');
    }

    if (key.startsWith('{{') || key.endsWith('}}')) {
        throw new Error('Macro key must not include the surrounding braces');
    }

    if (typeof value !== 'string' && typeof value !== 'function') {
        log.prompt.warn(`Macro value for "${key}" will be converted to a string`);
        value = MacrosParser.sanitizeMacroValue(value);
    }

    if (macros.registry.hasMacro(key)) {
        log.prompt.warn(`Macro ${key} is already registered`);
    }

    const legacyValue = value;

    macros.registry.registerMacro(key, {
        // Legacy-shaped macros never took arguments; keep the contract that only {{key}} without arguments is valid.
        category: 'legacy',
        description: typeof description === 'string' ? description : 'Automatically registered macro from extension context',
        handler: () => {
            let stored = legacyValue;

            if (typeof stored === 'function') {
                try {
                    const nonce = uuidv4();
                    stored = stored(nonce);
                } catch (e) {
                    log.prompt.warn(`Macro "${key}" function threw an error.`, e);
                    stored = '';
                }
            }

            return stored;
        },
    });
}

function unregisterContextMacro(key) {
    if (typeof key !== 'string') {
        throw new Error('Macro key must be a string');
    }

    key = key.trim();

    if (!key) {
        throw new Error('Macro key must not be empty or whitespace only');
    }

    macros.registry.unregisterMacro(key);
}

export function getContext() {
    return {
        accountStorage,
        chat,
        characters,
        groups,
        name1,
        name2,
        characterId: this_chid,
        groupId: selected_group,
        chatId: selected_group
            ? groups.find(x => x.id == selected_group)?.chat_id
            : (characters[this_chid]?.chat),
        getCurrentChatId,
        getRequestHeaders,
        reloadCurrentChat,
        renameChat,
        saveSettingsDebounced,
        onlineStatus: online_status,
        maxContext: Number(max_context),
        chatMetadata: chat_metadata,
        saveMetadataDebounced,
        streamingProcessor,
        eventSource,
        eventTypes: event_types,
        addOneMessage,
        deleteLastMessage,
        deleteMessage,
        generate: Generate,
        sendStreamingRequest,
        sendGenerationRequest,
        stopGeneration,
        tokenizers,
        /** @deprecated Use getTextTokensAsync instead */
        getTextTokens,
        getTextTokensAsync,
        decodeTextTokensAsync,
        /** @deprecated Use getTokenCountAsync instead */
        getTokenCount,
        getTokenCountAsync,
        extensionPrompts: extension_prompts,
        setExtensionPrompt,
        updateChatMetadata,
        saveChat: saveChatConditional,
        openCharacterChat,
        openGroupChat,
        saveMetadata,
        sendSystemMessage,
        activateSendButtons,
        deactivateSendButtons,
        saveReply,
        substituteParams,
        substituteParamsExtended,
        SlashCommandParser,
        SlashCommand,
        SlashCommandArgument,
        SlashCommandNamedArgument,
        SlashCommandEnumValue,
        ARGUMENT_TYPE,
        executeSlashCommandsWithOptions,
        /** @deprecated Use SlashCommandParser.addCommandObject() instead */
        registerSlashCommand,
        /** @deprecated Use executeSlashCommandWithOptions instead */
        executeSlashCommands,
        timestampToMoment,
        /** @deprecated Handlebars for extensions are no longer supported. */
        registerHelper: () => { },
        /** @deprecated Use `macros.register(name, { handler, description })` from scripts/macros/macro-system.js instead. */
        registerMacro: registerContextMacro,
        /** @deprecated Use `macros.registry.unregisterMacro(name)` from scripts/macros/macro-system.js instead. */
        unregisterMacro: unregisterContextMacro,
        registerFunctionTool: ToolManager.registerFunctionTool.bind(ToolManager),
        unregisterFunctionTool: ToolManager.unregisterFunctionTool.bind(ToolManager),
        isToolCallingSupported: ToolManager.isToolCallingSupported.bind(ToolManager),
        canPerformToolCalls: ToolManager.canPerformToolCalls.bind(ToolManager),
        ToolManager,
        registerDebugFunction,
        /** @deprecated Use renderExtensionTemplateAsync instead. */
        renderExtensionTemplate,
        renderExtensionTemplateAsync,
        registerDataBankScraper: ScraperManager.registerDataBankScraper.bind(ScraperManager),
        /** @deprecated Use callGenericPopup or Popup instead. */
        callPopup,
        callGenericPopup,
        /** @deprecated Use loader.show instead. */
        showLoader,
        /** @deprecated Use loader.hide instead. */
        hideLoader,
        mainApi: main_api,
        extensionSettings: extension_settings,
        ModuleWorkerWrapper,
        getTokenizerModel,
        generateQuietPrompt,
        generateRaw,
        generateRawData,
        writeExtensionField,
        writeExtensionFieldBulk,
        getThumbnailUrl,
        selectCharacterById,
        messageFormatting,
        shouldSendOnEnter,
        isMobile,
        t,
        translate,
        getCurrentLocale,
        addLocaleData,
        tags,
        tagMap: tag_map,
        menuType: menu_type,
        createCharacterData: create_save,
        /** @deprecated Legacy snake-case naming, compatibility with old extensions */
        event_types: event_types,
        Popup,
        POPUP_TYPE,
        POPUP_RESULT,
        chatCompletionSettings: oai_settings,
        textCompletionSettings: textgenerationwebui_settings,
        powerUserSettings: power_user,
        getCharacters,
        getOneCharacter,
        getCharacterCardFields,
        getCharacterSource,
        importFromExternalUrl,
        importTags,
        uuidv4,
        humanizedDateTime,
        updateMessageBlock,
        appendMediaToMessage,
        ensureMessageMediaIsArray,
        getMediaDisplay,
        getMediaIndex,
        scrollChatToBottom,
        scrollOnMediaLoad,
        macros,
        loader,
        swipe: {
            left: swipe_left,
            right: swipe_right,
            to: swipe,
            show: showSwipeButtons,
            hide: hideSwipeButtons,
            refresh: refreshSwipeButtons,
            isAllowed: isSwipingAllowed,
            state: () => swipeState,
        },
        variables: {
            local: {
                get: getLocalVariable,
                set: setLocalVariable,
                del: deleteLocalVariable,
                add: addLocalVariable,
                inc: incrementLocalVariable,
                dec: decrementLocalVariable,
                has: existsLocalVariable,
            },
            global: {
                get: getGlobalVariable,
                set: setGlobalVariable,
                del: deleteGlobalVariable,
                add: addGlobalVariable,
                inc: incrementGlobalVariable,
                dec: decrementGlobalVariable,
                has: existsGlobalVariable,
            },
        },
        loadWorldInfo,
        saveWorldInfo,
        reloadWorldInfoEditor: reloadEditor,
        updateWorldInfoList,
        convertCharacterBook,
        getWorldInfoPrompt,
        getWorldInfoNames: () => Array.isArray(world_names) ? [...world_names] : [],
        CONNECT_API_MAP,
        getTextGenServer,
        extractMessageFromData,
        getPresetManager,
        getChatCompletionModel,
        printMessages,
        clearChat,
        ChatCompletionService,
        TextCompletionService,
        ConnectionManagerRequestService,
        updateReasoningUI,
        parseReasoningFromString,
        getReasoningTemplateByName,
        unshallowCharacter,
        unshallowGroupMembers,
        getExtensionManifest,
        openThirdPartyExtensionMenu,
        symbols: {
            ignore: IGNORE_SYMBOL,
        },
        constants: {
            unset: UNSET_VALUE,
        },
    };
}

export default getContext;
