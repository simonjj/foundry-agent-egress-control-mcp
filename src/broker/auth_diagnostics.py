import logging

from jwt.exceptions import (
    ExpiredSignatureError,
    InvalidAlgorithmError,
    InvalidAudienceError,
    InvalidIssuerError,
    InvalidSignatureError,
    InvalidTokenError,
    MissingRequiredClaimError,
)

AUTH_LOGGER = logging.getLogger("uvicorn.error")


class AuthenticationError(PermissionError):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def authentication_failure_code(error: BaseException) -> str:
    if isinstance(error, AuthenticationError):
        return error.code
    if isinstance(error, PermissionError):
        message = str(error)
        if "Required delegated scope" in message:
            return "missing_scope"
        if "unsupported tenant" in message:
            return "invalid_tenant"
        if "does not identify a user" in message:
            return "missing_user_identity"
        return "permission_denied"
    if isinstance(error, ExpiredSignatureError):
        return "expired_token"
    if isinstance(error, InvalidAudienceError):
        return "invalid_audience"
    if isinstance(error, InvalidIssuerError):
        return "invalid_issuer"
    if isinstance(error, MissingRequiredClaimError):
        return "missing_required_claim"
    if isinstance(error, InvalidSignatureError):
        return "invalid_signature"
    if isinstance(error, InvalidAlgorithmError):
        return "unsupported_algorithm"
    if isinstance(error, (InvalidTokenError, ValueError)):
        return "invalid_token"
    return "unauthorized"


def log_authentication_failure(
    error: BaseException,
    method: str,
    path: str,
    authorization: str,
) -> None:
    AUTH_LOGGER.warning(
        "broker_auth_rejected code=%s method=%s path=%s "
        "authorization_present=%s bearer_scheme=%s",
        authentication_failure_code(error),
        method,
        path,
        bool(authorization),
        authorization.startswith("Bearer "),
    )
