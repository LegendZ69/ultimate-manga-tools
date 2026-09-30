import uvicorn


def main() -> None:
    # Remote devices should reach a private HTTPS reverse proxy; never expose this
    # development listener directly. One worker keeps paid concurrency at one.
    uvicorn.run("umt_server.app:create_app", factory=True, host="127.0.0.1", port=8787,
                workers=1, access_log=False, log_level="warning")


if __name__ == "__main__":
    main()
