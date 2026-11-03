import Foundation

// What the demo's pull request !4079, "Rename the order status enum", changed, and how it conflicts with main: it renames
// `OrderStatusCode` to `OrderStatus`, and `Cancelled` to `Canceled`, in the enum, the order service and the legacy mapper,
// adds tests and renames the page that documents them. Meanwhile main added a refund to the enum and the service, deleted
// the legacy mapper, added tests of its own at the same path, and moved the page into a folder.

extension DemoData {
    /// The files that conflict with a demo pull request's target branch: !4079's, and none for the others.
    public static func conflicts(of pullRequest: PullRequest) -> MergeConflicts {
        let files: [MergeConflict] = switch pullRequest.key.number {
        case 4079:
            [
                MergeConflict(id: 1, path: "/src/Orders/OrderStatus.cs", kind: .editEdit),
                MergeConflict(id: 2, path: "/src/Orders/OrderService.cs", kind: .editEdit),
                MergeConflict(id: 3, path: "/src/Orders/LegacyOrderMapper.cs", kind: .editDelete),
                MergeConflict(id: 4, path: "/tests/Orders/OrderStatusTests.cs", kind: .addAdd),
                MergeConflict(
                    id: 5, path: "/docs/order-states.md", kind: .rename1to2, sourcePath: "/docs/order-statuses.md",
                    targetPath: "/docs/orders/states.md"
                ),
            ]
        default:
            []
        }
        return MergeConflicts(files: files, of: pullRequest)
    }

    /// What the demo says a Copilot session answers when you ask it why a pull request's files conflict, with Explain: made
    /// up, as the rest of the demo's data is, never asked of Copilot. For !4079, whose rename of the order status enum
    /// conflicts with main in five files.
    public static func conflictsExplanation(pullRequest number: Int) -> String {
        guard number == 4079 else {
            return """
                This pull request and its target branch changed the same lines since they parted, so Git can't tell which to \
                keep. Merging the target branch in and keeping what both meant resolves them: start with the files both \
                changed, then build and run the tests that cover them.
                """
        }
        return """
            Each branch changed the same places since they parted:

            - **OrderStatus.cs**: this pull request renamed `OrderStatusCode` to `OrderStatus`, and `Cancelled` to \
            `Canceled`. main most likely added a value beside `Cancelled`, such as `Refunded`.
            - **OrderService.cs**: the same rename, where main likely handles that new value.
            - **LegacyOrderMapper.cs**: this pull request moved it to the new names, and main deleted it.
            - **OrderStatusTests.cs**: both branches added tests at this path.
            - **order-states.md**: renamed to `order-statuses.md` here, and moved to `docs/orders/states.md` on main.

            To resolve them, merge main in and keep both sides: main's new value and what handles it, under this pull \
            request's names, numbered as stored orders have it; let the mapper go, as main did, once nothing calls it; put \
            both sets of tests in one file; and keep the page where main moved it, with this pull request's wording. Then \
            build, and run the order tests.
            """
    }
}

extension DemoCode {
    /// !4079's change: the code in its first push, the tests and the page in its second.
    static let orderStatusRenameFiles: [File] = [
        File(path: "/src/Orders/OrderStatus.cs", base: orderStatusCode, versions: [orderStatus, orderStatus]),
        File(path: "/src/Orders/OrderService.cs", base: orderServiceBase, versions: [orderService, orderService]),
        File(path: "/src/Orders/LegacyOrderMapper.cs", base: legacyOrderMapperBase, versions: [legacyOrderMapper, legacyOrderMapper]),
        File(path: "/tests/Orders/OrderStatusTests.cs", base: nil, versions: [nil, orderStatusTests]),
        File(path: "/docs/order-statuses.md", originalPath: "/docs/order-states.md", base: orderStatesPage,
             versions: [orderStatesPage, orderStatusesPage]),
    ]

    static let orderStatusCode = """
    namespace Storefront.Payments.Orders;

    /// <summary>
    /// Where an order stands, from when it's placed to when it's shipped or cancelled.
    /// </summary>
    public enum OrderStatusCode
    {
        Pending = 0,
        Paid = 1,
        Shipped = 2,
        Cancelled = 3,
    }

    """

    static let orderStatus = """
    namespace Storefront.Payments.Orders;

    /// <summary>
    /// Where an order stands, from when it's placed to when it's shipped or canceled.
    /// </summary>
    public enum OrderStatus
    {
        Pending = 0,
        Paid = 1,
        Shipped = 2,
        Canceled = 3,
    }

    """

    static let orderServiceBase = """
    using System;
    using System.Threading;
    using System.Threading.Tasks;

    namespace Storefront.Payments.Orders;

    /// <summary>
    /// Moves orders from one status to the next as they're paid, shipped or cancelled.
    /// </summary>
    public sealed class OrderService
    {
        private readonly IOrderRepository orders;

        public OrderService(IOrderRepository orders)
        {
            this.orders = orders;
        }

        public async Task MarkPaidAsync(Guid orderId, CancellationToken cancellation)
        {
            var order = await orders.GetAsync(orderId, cancellation);
            if (order.Status != OrderStatusCode.Pending)
            {
                throw new InvalidOperationException($"Order {orderId} is {order.Status}, not pending.");
            }
            order.Status = OrderStatusCode.Paid;
            await orders.SaveAsync(order, cancellation);
        }

        public async Task CancelAsync(Guid orderId, CancellationToken cancellation)
        {
            var order = await orders.GetAsync(orderId, cancellation);
            if (order.Status == OrderStatusCode.Shipped)
            {
                throw new InvalidOperationException($"Order {orderId} has shipped already.");
            }
            order.Status = OrderStatusCode.Cancelled;
            await orders.SaveAsync(order, cancellation);
        }
    }

    """

    static let orderService = """
    using System;
    using System.Threading;
    using System.Threading.Tasks;

    namespace Storefront.Payments.Orders;

    /// <summary>
    /// Moves orders from one status to the next as they're paid, shipped or canceled.
    /// </summary>
    public sealed class OrderService
    {
        private readonly IOrderRepository orders;

        public OrderService(IOrderRepository orders)
        {
            this.orders = orders;
        }

        public async Task MarkPaidAsync(Guid orderId, CancellationToken cancellation)
        {
            var order = await orders.GetAsync(orderId, cancellation);
            if (order.Status != OrderStatus.Pending)
            {
                throw new InvalidOperationException($"Order {orderId} is {order.Status}, not pending.");
            }
            order.Status = OrderStatus.Paid;
            await orders.SaveAsync(order, cancellation);
        }

        public async Task CancelAsync(Guid orderId, CancellationToken cancellation)
        {
            var order = await orders.GetAsync(orderId, cancellation);
            if (order.Status == OrderStatus.Shipped)
            {
                throw new InvalidOperationException($"Order {orderId} has shipped already.");
            }
            order.Status = OrderStatus.Canceled;
            await orders.SaveAsync(order, cancellation);
        }
    }

    """

    static let legacyOrderMapperBase = """
    using System;

    namespace Storefront.Payments.Orders;

    /// <summary>
    /// Reads the one-letter status codes that orders from the old checkout still carry.
    /// </summary>
    public static class LegacyOrderMapper
    {
        public static OrderStatusCode FromCode(char code) => code switch
        {
            'P' => OrderStatusCode.Pending,
            'A' => OrderStatusCode.Paid,
            'S' => OrderStatusCode.Shipped,
            'C' => OrderStatusCode.Cancelled,
            _ => throw new ArgumentOutOfRangeException(nameof(code), code, "Not a legacy order status."),
        };
    }

    """

    static let legacyOrderMapper = """
    using System;

    namespace Storefront.Payments.Orders;

    /// <summary>
    /// Reads the one-letter status codes that orders from the old checkout still carry.
    /// </summary>
    public static class LegacyOrderMapper
    {
        public static OrderStatus FromCode(char code) => code switch
        {
            'P' => OrderStatus.Pending,
            'A' => OrderStatus.Paid,
            'S' => OrderStatus.Shipped,
            'C' => OrderStatus.Canceled,
            _ => throw new ArgumentOutOfRangeException(nameof(code), code, "Not a legacy order status."),
        };
    }

    """

    static let orderStatusTests = """
    using Storefront.Payments.Orders;
    using Xunit;

    namespace Storefront.Payments.Tests.Orders;

    public class OrderStatusTests
    {
        [Theory]
        [InlineData(OrderStatus.Pending, 0)]
        [InlineData(OrderStatus.Paid, 1)]
        [InlineData(OrderStatus.Shipped, 2)]
        [InlineData(OrderStatus.Canceled, 3)]
        public void KeepsTheNumbersStoredOrdersHave(OrderStatus status, int stored)
        {
            Assert.Equal(stored, (int)status);
        }
    }

    """

    static let orderStatesPage = """
    # Order states

    An order is **Pending** until it's paid, **Paid** until it ships, then **Shipped**. It can be **Cancelled** until it
    ships.

    Stored orders keep each state as a number, so never renumber them.

    """

    static let orderStatusesPage = """
    # Order statuses

    An order is **Pending** until it's paid, **Paid** until it ships, then **Shipped**. It can be **Canceled** until it
    ships.

    Stored orders keep each status as a number (`OrderStatus`, in `src/Orders/OrderStatus.cs`), so never renumber them.

    """
}
