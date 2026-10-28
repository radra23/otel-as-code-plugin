using Microsoft.AspNetCore.Mvc;

namespace OrdersApi.Controllers;

[ApiController]
[Route("orders")]
public class OrdersController : ControllerBase
{
    [HttpGet("{id}")]
    public IActionResult Get(string id) => Ok(new { id });
}
