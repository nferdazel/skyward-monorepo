// Package httperr — error envelope JSON konsisten + mapping ke HTTP status.
package httperr

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// Code — kode error machine-readable untuk klien.
type Code string

const (
	CodeNotFound     Code = "not_found"
	CodeConflict     Code = "conflict"
	CodeValidation   Code = "validation_error"
	CodeUnavailable  Code = "service_unavailable"
	CodeInternal     Code = "internal"
	CodeDatabase     Code = "database_error"
	CodeUnauthorized Code = "unauthorized"
	CodeTooMany      Code = "too_many_requests"
)

// Error — error ter-struktur yang bisa di-map ke HTTP response.
type Error struct {
	Code    Code
	Message string
	Err     error // error asli (tidak dikirim ke klien; untuk log)
}

func (e *Error) Error() string { return e.Message }
func (e *Error) Unwrap() error { return e.Err }

// New — buat Error tanpa cause.
func New(code Code, message string) *Error { return &Error{Code: code, Message: message} }

// Wrap — buat Error dengan membungkus error asli.
func Wrap(code Code, message string, err error) *Error {
	return &Error{Code: code, Message: message, Err: err}
}

// NotFound — 404.
func NotFound(msg string) *Error { return New(CodeNotFound, msg) }

// Conflict — 409.
func Conflict(msg string) *Error { return New(CodeConflict, msg) }

// Validation — 400.
func Validation(msg string) *Error { return New(CodeValidation, msg) }

// Unavailable — 503.
func Unavailable(msg string) *Error { return New(CodeUnavailable, msg) }

// Internal — 500.
func Internal(msg string) *Error { return New(CodeInternal, msg) }

// Unauthorized — 401.
func Unauthorized(msg string) *Error { return New(CodeUnauthorized, msg) }

// TooManyRequests — 429.
func TooManyRequests(msg string) *Error { return New(CodeTooMany, msg) }

var statusByCode = map[Code]int{
	CodeNotFound:     http.StatusNotFound,
	CodeConflict:     http.StatusConflict,
	CodeValidation:   http.StatusBadRequest,
	CodeUnauthorized: http.StatusUnauthorized,
	CodeUnavailable:  http.StatusServiceUnavailable,
	CodeInternal:     http.StatusInternalServerError,
	CodeDatabase:     http.StatusInternalServerError,
	CodeTooMany:      http.StatusTooManyRequests,
}

// WriteError menulis error envelope JSON. Error non-httperr → 500.
func WriteError(w http.ResponseWriter, logger *slog.Logger, err error) {
	var he *Error
	if !asError(err, &he) {
		if logger != nil {
			logger.Error("unhandled error", "error", err)
		}
		he = Internal("internal error")
	} else if he.Code == CodeInternal || he.Code == CodeDatabase {
		if logger != nil {
			logger.Error("server error", "code", he.Code, "message", he.Message, "cause", he.Err)
		}
	}
	status := statusByCode[he.Code]
	if status == 0 {
		status = http.StatusInternalServerError
	}
	if he.Code == CodeTooMany {
		w.Header().Set("Retry-After", "1")
	}
	WriteJSON(w, status, map[string]any{
		"error": map[string]string{"code": string(he.Code), "message": he.Message},
	})
}

// WriteJSON menulis response JSON.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// asError memeriksa err (termasuk wrapped) dan mengisi target.
func asError(err error, target **Error) bool {
	if err == nil {
		return false
	}
	for err != nil {
		if e, ok := err.(*Error); ok {
			*target = e
			return true
		}
		type unwrapper interface{ Unwrap() error }
		u, ok := err.(unwrapper)
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}
