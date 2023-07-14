module peque.exception;

import std.exception;

class PequeException : Exception {
    mixin basicExceptionCtors;
}
