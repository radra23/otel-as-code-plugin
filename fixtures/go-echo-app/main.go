package main

import "github.com/labstack/echo/v4"

func main() {
	e := echo.New()
	e.GET("/health", func(c echo.Context) error {
		return c.NoContent(200)
	})
	e.Start(":8080")
}
