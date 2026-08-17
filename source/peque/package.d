module peque;

public import peque.connection:    Connection, Transaction, OnSuccess, IsolationLevel,
                                   PreparedStatement, Notification;
public import peque.result:        Result;
public import peque.wait_strategy: isWaitStrategy, hasTimedWait, WaitMask,
                                   PollWaitStrategy, MockWaitStrategy, MockWS;
public import peque.query_context: isQueryContext;
public import peque.pool:          ConnectionPool, ThreadConnectionPool;
// The UDAs that affect CORE behaviour: hydration reads @model/@field/
// @primaryKey/@autoHydrate, and recognises a @many2one field as a real column
// via hasMany2OneUDA — so omitting many2one here was wrong even for core's own
// feature set. @related/@one2many/@many2many are listed because a model that
// declares them must still compile against the core package alone.
// Schema-only UDAs (@unique, @check, @pgType, @index…, @defaultOrder) mean
// nothing without peque:orm and are re-exported from there instead.
public import peque.model:         model, field, primaryKey, autoHydrate,
                                   many2one, related, one2many, many2many,
                                   OnDelete, hasMany2OneUDA;
public import peque.hydration:     camelToSnake;
