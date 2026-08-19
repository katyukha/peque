module peque;

public import peque.connection:    Connection, Transaction, OnSuccess, IsolationLevel,
                                   PreparedStatement, Notification;
public import peque.result:        Result;
public import peque.wait_strategy: isWaitStrategy, hasTimedWait, WaitMask,
                                   PollWaitStrategy, MockWaitStrategy, MockWS;
public import peque.query_context: isQueryContext;
public import peque.pool:          ConnectionPool, ThreadConnectionPool;
// UDAs that affect core hydration, plus the relation UDAs a model may declare.
// Schema-only UDAs (@unique, @check, @pgType, @index…) mean nothing without
// peque:orm and are re-exported from there.
public import peque.model:         model, field, primaryKey, autoHydrate,
                                   many2one, related, one2many, many2many,
                                   OnDelete, hasMany2OneUDA;
public import peque.hydration:     camelToSnake;

// The whole exception tree — callers cannot avoid naming these.
public import peque.exception;
