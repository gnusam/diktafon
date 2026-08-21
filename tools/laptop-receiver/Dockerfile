# The receiver has no dependencies — the image exists only to give it a
# python and a `notify-send` binary.
FROM python:3.13-alpine

RUN apk add --no-cache libnotify

WORKDIR /app
COPY receiver.py /app/receiver.py

EXPOSE 8099
CMD ["python3", "-u", "/app/receiver.py"]
