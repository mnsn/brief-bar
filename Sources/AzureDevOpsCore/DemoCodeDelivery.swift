import Foundation

extension DemoCode {
    /// The delivery estimates that the demo's failing pull request adds: its first push used the server's time zone for
    /// the cutoff, on line 27, and its second the warehouse's.
    static let deliveryEstimates = Changes(pushedAgo: [nil, 28.5 * 3_600], files: [
        File(path: "/src/Delivery/DeliveryEstimate.cs", base: nil, versions: [deliveryEstimateServerTime, deliveryEstimateWarehouseTime]),
    ])

    static let deliveryEstimateServerTime = """
    using System;

    namespace Storefront.Delivery;

    /// <summary>
    /// When an order placed now arrives, as the product page says it.
    /// </summary>
    public sealed class DeliveryEstimate
    {
        /// <summary>Orders placed before this time of day leave the warehouse the same day.</summary>
        private static readonly TimeSpan Cutoff = new(14, 0, 0);

        private readonly TimeProvider time;
        private readonly Warehouse warehouse;

        public DeliveryEstimate(TimeProvider time, Warehouse warehouse)
        {
            this.time = time;
            this.warehouse = warehouse;
        }

        /// <summary>
        /// The first day an order placed now can arrive: the working day after it leaves the warehouse and travels.
        /// </summary>
        public DateOnly EarliestArrival()
        {
            var now = time.GetLocalNow();
            var leaves = DateOnly.FromDateTime(now.DateTime);
            if (now.TimeOfDay >= Cutoff)
            {
                leaves = leaves.AddDays(1);
            }

            return NextWorkingDay(leaves.AddDays(warehouse.TransitDays));
        }

        private static DateOnly NextWorkingDay(DateOnly day) => day.DayOfWeek switch
        {
            DayOfWeek.Saturday => day.AddDays(2),
            DayOfWeek.Sunday => day.AddDays(1),
            _ => day,
        };
    }

    """

    static let deliveryEstimateWarehouseTime = """
    using System;

    namespace Storefront.Delivery;

    /// <summary>
    /// When an order placed now arrives, as the product page says it.
    /// </summary>
    public sealed class DeliveryEstimate
    {
        /// <summary>Orders placed before this time of day, where the warehouse is, leave it the same day.</summary>
        private static readonly TimeSpan Cutoff = new(14, 0, 0);

        private readonly TimeProvider time;
        private readonly Warehouse warehouse;

        public DeliveryEstimate(TimeProvider time, Warehouse warehouse)
        {
            this.time = time;
            this.warehouse = warehouse;
        }

        /// <summary>
        /// The first day an order placed now can arrive: the working day after it leaves the warehouse and travels.
        /// </summary>
        public DateOnly EarliestArrival()
        {
            // The cutoff is the warehouse's, wherever the server runs.
            var now = TimeZoneInfo.ConvertTime(time.GetUtcNow(), warehouse.TimeZone);
            var leaves = DateOnly.FromDateTime(now.DateTime);
            if (now.TimeOfDay >= Cutoff)
            {
                leaves = leaves.AddDays(1);
            }

            return NextWorkingDay(leaves.AddDays(warehouse.TransitDays));
        }

        private static DateOnly NextWorkingDay(DateOnly day) => day.DayOfWeek switch
        {
            DayOfWeek.Saturday => day.AddDays(2),
            DayOfWeek.Sunday => day.AddDays(1),
            _ => day,
        };
    }

    """
}
