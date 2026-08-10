from .config import HelperConfig
from .server import serve


def main() -> None:
    serve(HelperConfig.from_env())


if __name__ == "__main__":
    main()
