msg=$1

hugo && git add . && git commit -m "$msg" && git push origin master