////////////////// LOCAL STORAGE HANDLING /////////////////////
import { log } from './log.js';

/**
 * @deprecated THIS FUNCTION IS OBSOLETE. DO NOT USE
 */
export function SaveLocal(target, val) {
    localStorage.setItem(target, val);
    log.sys.debug('SaveLocal -- ' + target + ' : ' + val);
}
/**
 * @deprecated THIS FUNCTION IS OBSOLETE. DO NOT USE
 */
export function LoadLocal(target) {
    log.sys.debug('LoadLocal -- ' + target);
    return localStorage.getItem(target);
}
/**
 * @deprecated THIS FUNCTION IS OBSOLETE. DO NOT USE
 */
export function LoadLocalBool(target) {
    let result = localStorage.getItem(target) === 'true';
    return result;
}
/**
 * @deprecated THIS FUNCTION IS OBSOLETE. DO NOT USE
 */
export function CheckLocal() {
    log.sys.debug('----------local storage---------');
    var i;
    for (i = 0; i < localStorage.length; i++) {
        log.sys.debug(localStorage.key(i) + ' : ' + localStorage.getItem(localStorage.key(i)));
    }
    log.sys.debug('------------------------------');
}

/**
 * @deprecated THIS FUNCTION IS OBSOLETE. DO NOT USE
 */
export function ClearLocal() { localStorage.clear(); log.sys.debug('Removed All Local Storage'); }

/////////////////////////////////////////////////////////////////////////
