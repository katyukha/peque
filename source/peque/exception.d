module peque.exception;

import std.exception;

class PequeException : Exception {
    mixin basicExceptionCtors;
}

class RowNotExistsError : PequeException {
    mixin basicExceptionCtors;
}

class ColNotExistsError : PequeException {
    mixin basicExceptionCtors;
}

class ConversionError : PequeException {
    mixin basicExceptionCtors;
}

class QueryError : PequeException {
    mixin basicExceptionCtors;
}
